"""
Classifier for audit events.

This file contains logic for classifying events before they are ingested by 
the NATS AUDIT_MT Stream. We are interested in events that are related to
our multitenant cluster standards only. This can be modified to fit the
needs of different clusters.

NAMESPACE_RESOURCE_PERMISSION_MAP maps kubernetes resources and verbs to a more
abstracted version, which is then used by the TLA specification. Same for
DEFAULT_CLUSTER_ROLES_PERMISSION_MAP.
"""

# -----------------------------------------------------------------------------
# HELPER VARS
# -----------------------------------------------------------------------------

READ_VERBS = {"get", "list", "watch"}
WRITE_VERBS = {"create", "update", "patch"}
DELETE_VERBS = {"delete", "deletecollection"}

MONITORED_NAMESPACES = {"tenant-a", "tenant-b"}

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

def is_monitored_namespace_name(name: str | None) -> bool:
    """
    Checks if the namespace is one of the ones we monitor.

    Args: namespace name

    Returns: True if it's in MONITORED_NAMESPACES
    """
    return name in MONITORED_NAMESPACES

def is_system_group(ev):
    """
    Checks if the actor group is a system group.

    Args: event json

    Returns: True if system group we wish to ignore, False owise.
    """
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
    """
    Checks if the log is an actual access attempt.
    
    Args: audit log event json
    
    Returns: False if not a relevant access attempt, abstracted permission
    if actual access attempt.
    """
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}

    resource = obj.get("resource")
    namespace = obj.get("namespace")
    subresource = obj.get("subresource")
    
    if is_system_group(ev):
        return False

    if not namespace:
        return False
    
    if namespace not in MONITORED_NAMESPACES:
        return False
    
    # Ignore pod/log, pod/exec, pod/status etc.
    if subresource:
        return False

    return (resource, verb) in NAMESPACE_RESOURCE_PERMISSION_MAP

def classify_event(ev: dict) -> str | None:
    """
    Classifies audit log events and adds a new field that contains
    this classification for ease of processing inside the TLA
    specification.

    Args: audit log event json

    Returns: classification of event or None if not relevant
    """
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}
    resp = ev.get("responseStatus") or {}

    resource = obj.get("resource")
    code = resp.get("code")

    if verb == "create" and resource == "namespaces" and code in SUCCESS_CODES:
        name = obj.get("name")
        if is_monitored_namespace_name(name):
            return "ns.created"
        return None

    if verb == "create" and resource == "clusterroles" and code in SUCCESS_CODES:
        return "clusterrole.created"

    if verb == "create" and resource == "rolebindings" and code in SUCCESS_CODES:
        return "rolebinding.created"

    if verb == "create" and resource == "clusterrolebindings" and code in SUCCESS_CODES:
        return "clusterrolebinding.created"

    if is_access_attempt(ev):
        return "access.attempt"
        
    if verb == "delete" and resource == "namespaces" and code in SUCCESS_CODES:
        name = obj.get("name")
        if is_monitored_namespace_name(name):
            return "ns.deleted"
        return None

    if verb == "delete" and resource == "clusterroles" and code in SUCCESS_CODES:
        return "clusterrole.deleted"

    if verb == "delete" and resource == "rolebindings" and code in SUCCESS_CODES:
        return "rolebinding.deleted"

    if verb == "delete" and resource == "clusterrolebindings" and code in SUCCESS_CODES:
        return "clusterrolebinding.deleted"

    return None

def classify_access_attempts_permission(ev: dict) -> str | None:
    """
    Includes an access attempt event's abstracted
    permission in the event json, before feeding it to NATS.

    Args: access attempt event json

    Returns: highly abstracted permission from NAMESPACE_RESOURCE_PERMISSION_MAP
    """
    verb = ev.get("verb")
    obj = ev.get("objectRef") or {}
    resource = obj.get("resource")

    type = ev.get("tlaType")

    if type != "access.attempt":
        return None
    
    return NAMESPACE_RESOURCE_PERMISSION_MAP.get((resource, verb), "no-permission")

def max_permission(a, b):
    """
    Compares tiers of 2 permissions based on our abstraction.

    Args: 2 abstracted permissions.

    Returns: the one with better tier.
    """
    if PERMISSION_TIER[b] > PERMISSION_TIER[a]:
        return b
    return a

def permission_from_rules(rules: list[dict]) -> str:
    """
    Identifies permissions in role rules based on the abstraction.
    Roles can have multiple mappings of resources and verbs. This
    function returns the abstracted permission result, based on
    the highest tier of permissions in the rules.

    Args: content of a `rules` field in a ClusterRole creation log

    Returns: one of the 5 abstracted permissions: none, read, write
    admin-powers, cluster-admin-powers
    """
    result = "none"

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

def permission_from_clusterrole_rules(ev):
    """
    Classify non-default cluster roles based on the highest-tier permission.

    Args: an audit event (json)

    Returns: one of the 5 abstracted permissions.
    """
    if (
        ev.get("tlaType") in {"clusterrole.created", "clusterrole.updated"}
        and (ev.get("requestObject") or {})
                .get("metadata", {})
                .get("name") not in {"view", "edit", "admin", "cluster-admin"}
        ):

        rules = (ev.get("requestObject") or {}).get("rules") or []

        return permission_from_rules(rules)
