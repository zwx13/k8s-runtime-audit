import os

TENANT_COUNT = int(os.getenv("MT_TENANT_COUNT", "2"))

TENANTS = {
    f"tenant-{i}"
    for i in range(1, TENANT_COUNT + 1)
}