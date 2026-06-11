# -----------------------------------------------------------------------------
# HELPER ENV VARS
# -----------------------------------------------------------------------------
READ_VERBS = {"get", "list", "watch"}
WRITE_VERBS = {"create", "update", "patch"}
DELETE_VERBS = {"delete", "deletecollection"}

SUCCESS_CODES= {200, 201}

NAMESPACE_RESOURCE_PERMISSION_MAP = {
    # Pods
    ("pods", "get"): "read",
    ("pods", "list"): "read",
    ("pods", "watch"): "read",
    ("pods", "create"): "write",
    ("pods", "update"): "write",
    ("pods", "patch"): "write",
    ("pods", "delete"): "write",
    ("pods", "deletecollection"): "write",

     # Services
    ("services", "get"): "read",
    ("services", "list"): "read",
    ("services", "watch"): "read",
    ("services", "create"): "write",
    ("services", "update"): "write",
    ("services", "patch"): "write",
    ("services", "delete"): "write",
    ("services", "deletecollection"): "write",

    # ConfigMaps
    ("configmaps", "get"): "read",
    ("configmaps", "list"): "read",
    ("configmaps", "watch"): "read",
    ("configmaps", "create"): "write",
    ("configmaps", "update"): "write",
    ("configmaps", "patch"): "write",
    ("configmaps", "delete"): "write",
    ("configmaps", "deletecollection"): "write",

    # Secrets
    ("secrets", "get"): "admin-powers",
    ("secrets", "list"): "admin-powers",
    ("secrets", "watch"): "admin-powers",
    ("secrets", "create"): "admin-powers",
    ("secrets", "update"): "admin-powers",
    ("secrets", "patch"): "admin-powers",
    ("secrets", "delete"): "admin-powers",
    ("secrets", "deletecollection"): "admin-powers",
}

DEFAULT_CLUSTER_ROLES_PERMISSION_MAP = {
    "view": "read",
    "edit": "write",
    "admin": "admin-powers",
    "cluster-admin": "cluster-admin-powers"
}

PERMISSION_TIER = {
    "none": 0,
    "read": 1,
    "write": 2,
    "admin-powers": 3,
    "cluster-admin-powers": 4
}

SYSTEM_GROUPS = {
    "system:nodes",
    "system:serviceaccounts",
}

# -----------------------------------------------------------------------------
# Logic
# -----------------------------------------------------------------------------

def is_system_group(ev):
    imp = ev.get("impersonatedUser") or {}
    
    if imp.get("groups"):
        action_groups = set(imp.get("groups") or [])
    else:
        user = ev.get("user") or {}
        action_groups = set(user.get("groups") or [])

    if action_groups & {"system:nodes", "system:serviceaccounts"}:
        return True
    
    return False

def is_access_attempt(ev):
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}

    resource = obj.get("resource")
    namespace = obj.get("namespace")
    subresource = obj.get("subresource")
    
    if is_system_group(ev):
        return False

    if not namespace:
        return False
    
    # Ignore pod/log, pod/exec, pod/status etc.
    if subresource:
        return False

    return (resource, verb) in NAMESPACE_RESOURCE_PERMISSION_MAP

def classify_event(ev: dict) -> str | None:
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}
    resp = ev.get("responseStatus") or {}

    resource = obj.get("resource")
    code = resp.get("code")

    if verb == "create" and resource == "namespaces" and code in SUCCESS_CODES:
        return "ns.created"

    if verb == "create" and resource == "clusterroles" and code in SUCCESS_CODES:
        return "clusterrole.created"

    if verb == "create" and resource == "rolebindings" and code in SUCCESS_CODES:
        return "rolebinding.created"

    if verb == "create" and resource == "clusterrolebinding" and code in SUCCESS_CODES:
        return "clusterrolebinding.created"

    if is_access_attempt(ev):
        return "access.attempt"
        
    if verb == "delete" and resource == "namespaces" and code in SUCCESS_CODES:
        return "ns.deleted"

    if verb == "delete" and resource == "clusterroles" and code in SUCCESS_CODES:
        return "clusterrole.deleted"

    if verb == "delete" and resource == "rolebindings" and code in SUCCESS_CODES:
        return "rolebinding.deleted"

    if verb == "delete" and resource == "clusterrolebindings" and code in SUCCESS_CODES:
        return "clusterrolebinding.deleted"

    return None

def classify_access_attempts_permission(ev: dict) -> str | None:
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}
    resource = obj.get("resource")

    type = ev.get("tlaType")

    if type != "access.attempt":
        return None
    
    return NAMESPACE_RESOURCE_PERMISSION_MAP.get((resource, verb), "no-permission")

def max_permission(a, b):
    if PERMISSION_TIER[b] > PERMISSION_TIER[a]:
        return b
    return a

def permission_from_clusterrole_rules(ev):
    result = "none"
    if (
        ev.get("tlaType") in {"clusterrole.created", "clusterrole.updated"}
        and (ev.get("requestObject") or {})
                .get("metadata", {})
                .get("name") not in {"view", "edit", "admin", "cluster-admin"}
        ):

        rules = ev.get("requestObject" or {}).get("rules" or {})

        for rule in rules or []:
            resources = rule.get("resources") or []
            verbs = rule.get("verbs") or []

            for resource in resources:
                for verb in verbs:
                    if resource == "*" or verb == "*":
                        result = max_permission(result, "cluster-admin-powers")
                        continue
                
                    permission = NAMESPACE_RESOURCE_PERMISSION_MAP.get((resource, verb))
                   
                    if permission is not None:
                        result = max_permission(result, permission)

        return result