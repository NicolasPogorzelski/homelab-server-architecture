# Collabora Online as a Container Beside Nextcloud

## Status
Implemented 2026-11-18. Supersedes / superseded by: -.

## Context
Documents in Nextcloud are opened with Collabora Online. The `richdocumentscode` app ran it as an
AppImage that Apache's PHP started under `www-data`, reached through `proxy.php`.

Verified 2026-11-18: an opened document showed "the server has been disconnected"; every Apache
restart killed the process (`apache2.service: Killing process ... (coolwsd)` in the journal); the
AppImage ran without its sandbox; by a browser test and `journalctl` on lxc210.

The person edits OpenDocument files as often as Microsoft Office files, so both must open and
save.

## Options
- **Keep the built-in server.** No work, but the WebSocket through `proxy.php` drops, and it starts
  and dies with Apache.
- **OnlyOffice Docs.** The closest fidelity for `.docx`, `.xlsx` and `.pptx`, but it converts
  OpenDocument files on open and save, and it needs 2-4 GB of memory.
- **Collabora Online as its own container.** The same editor on LibreOffice, native with
  OpenDocument and good with Microsoft formats; Nextcloud's recommended deployment.

## Decision
`collabora/code`, pinned by tag and digest, runs in Docker on lxc210 and publishes
`127.0.0.1:9980` only. Apache proxies its paths, the WebSocket included, on the Nextcloud name, so
no new node, tag or ACL rule is needed. lxc210 goes from 2 to 4 GB of memory.

## Consequences
- Browser, Nextcloud and Collabora all use the Nextcloud name. Moving Nextcloud behind
  `tailscale serve` still needs lxc210 to reach its own name first
  ([remediation plan](../platform/remediation-plan.md)).
- The container's sandbox runs; jails are copied instead of bind-mounted, which slows the first
  open of a document.
- Nextcloud keeps the discovery in APCu inside Apache; after changing a `richdocuments` URL,
  Apache is restarted, or browsers keep the old editor address.
- Dependabot proposes image updates like for the other compose stacks.

Verified 2026-11-18: a `.docx` and an `.odt` opened and reached `Document_Loaded` without
WebSocket errors, by the browser console; `/hosting/discovery` and the editor page answered 200
from the notebook, by `curl`.
