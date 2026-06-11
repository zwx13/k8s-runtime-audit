import asyncio
import json
import logging
import os
from typing import Any

from classifier import (
    DEFAULT_CLUSTER_ROLES_PERMISSION_MAP,
    permission_from_rules,
    )

log = logging.getLogger(__name__)

KUBECTL = os.getenv("KUBECTL", "kubectl")

MONITORED_NAMESPACES = {"tenant-a", "tenant-b"}

MONITORED_CLUSTERROLES = {"dev"}

MONITORED_ROLEBINDINGS = {
    ("tenant-a", "tenant-a-binding"),
    ("tenant-b", "tenant-b-binding"),
}

MONITORED_CLUSTERROLEBINDING_SUBJECTS = {
    "kubeadm:cluster-admins",
    "tenant-a",
    "tenant-b",
}

async def kubectl_get_json(*args: str) -> dict[str, Any]:
    proc = await asyncio.create_subprocess_exec(
        KUBECTL,
        *args,
        "-o",
        "json",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    stdout, stderr = await proc.communicate()

    if proc.returncode != 0:
        raise RuntimeError(
            f"kubectl {' '.join(args)} -o json failed: {stderr.decode().strip()}"
        )

    return json.loads(stdout.decode())

async def build_cached_state() -> dict[str, Any]:
    namespaces = await kubectl_get_json("get", "namespaces")
    clusterroles = await kubectl_get_json("get", "clusterroles")
    rolebindings = await kubectl_get_json("get", "rolebindings", "-A")
    clusterrolebindings = await kubectl_get_json("get", "clusterrolebindings")

    cached_state = {
        "nsTenant": build_ns_tenant(namespaces),
        "clusterRoles": build_cluster_roles(clusterroles),
        "roleBindings": build_role_bindings(rolebindings),
        "clusterRoleBindings": build_cluster_role_bindings(clusterrolebindings),
    }

    log.info(
        "Built cachedState: namespaces=%s clusterRoles=%s roleBindings=%s clusterRoleBindings=%s",
        len(cached_state["nsTenant"]),
        len(cached_state["clusterRoles"]),
        len(cached_state["roleBindings"]),
        len(cached_state["clusterRoleBindings"]),
    )

    return cached_state

def build_ns_tenant(namespaces: dict[str, Any]) -> list[list[str]]:
    result: list[list[str]] = []

    for ns in namespaces.get("items", []):
        metadata = ns.get("metadata") or {}
        name = metadata.get("name")

        if name not in MONITORED_NAMESPACES:
            continue

        labels = metadata.get("labels") or {}

        tenant = labels.get("tenant")

        result.append([name, tenant])

    return sorted(result, key=lambda x: x[0])


def build_cluster_roles(clusterroles: dict[str, Any]) -> list[list[str]]:
    result: list[list[str]] = []

    for name, permission in DEFAULT_CLUSTER_ROLES_PERMISSION_MAP.items():
        result.append([name, permission])

    seen = set(DEFAULT_CLUSTER_ROLES_PERMISSION_MAP.keys())

    for cr in clusterroles.get("items", []):
        metadata = cr.get("metadata") or {}
        name = metadata.get("name")

        if not name:
            continue

        if name in seen:
            continue

        if name not in MONITORED_CLUSTERROLES:
            continue

        permission = permission_from_rules(cr.get("rules") or [])

        result.append([name, permission])
        seen.add(name)

    return result


def first_subject_name(binding: dict[str, Any]) -> str | None:
    subjects = binding.get("subjects") or []

    if not subjects:
        return None

    return subjects[0].get("name")


def build_role_bindings(rolebindings: dict[str, Any]) -> list[list[list[str]]]:
    result: list[list[list[str]]] = []

    for rb in rolebindings.get("items", []):
        metadata = rb.get("metadata") or {}
        namespace = metadata.get("namespace")
        name = metadata.get("name")

        if (namespace, name) not in MONITORED_ROLEBINDINGS:
            continue

        subject_name = first_subject_name(rb)
        role_ref = rb.get("roleRef") or {}
        role_name = role_ref.get("name")

        if not namespace or not name or not subject_name or not role_name:
            continue

        result.append([
            [namespace, name],
            [subject_name, role_name],
        ])

    return sorted(result, key=lambda x: (x[0][0], x[0][1]))


def build_cluster_role_bindings(clusterrolebindings: dict[str, Any]) -> list[list[Any]]:
    result: list[list[Any]] = []

    for crb in clusterrolebindings.get("items", []):
        role_ref = crb.get("roleRef") or {}
        role_name = role_ref.get("name")

        if not role_name:
            continue

        for subject in crb.get("subjects") or []:
            subject_name = subject.get("name")

            if not subject_name:
                continue

            if subject_name not in MONITORED_CLUSTERROLEBINDING_SUBJECTS:
                continue

            result.append([
                role_name,
                [subject_name, role_name],
            ])

    return sorted(result, key=lambda x: (x[0], x[1][0]))