This workflow builds two public upstream releases with selected dependency patches.
It produces GitHub Actions artifacts.
It has no deployment step and receives no owner service credentials.

The recipes pin the upstream source commits and base images.
Each artifact contains an image archive, its checksum, the image ID, binary checksums, dependency manifests and a Grype report.
The build fails when Grype finds a critical vulnerability.
Other vulnerability matches can remain.
A package match does not establish a reachable exploit.

The workflow runs only in `lmtlssss/lnd`.
The branch push starts both builds.
The artifact retention period is seven days.

Before a rollout:

1. Verify the workflow commit and its successful conclusion.
2. Verify the archive checksum and loaded image ID.
3. Preserve the exact container configuration without printing credentials.
4. Stop only the application that needs the upgrade.
5. Make a cold backup of its data and configuration.
6. Restore that backup in an isolated container without external network access.
7. Verify application state and the required API responses.
8. Recreate the application with its existing network, mounts and port configuration.
9. Verify the application and its consumers.
10. Preserve the matching backup and original image for rollback.

After a database migration, restore the matching cold backup before a rollback.
An image rollback alone can fail against migrated data.
The device-control containers and protected host network configuration remain outside this rollout.
