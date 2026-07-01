# ZeroServer Community Cloud — Agent Runner

Public distribution for the **ZeroServer Community Cloud (ZSC)** provider agent
(`zsc-agent`). Providers share their machines' idle time with the community
cloud; the agent monitors the host and runs the workloads scheduled to it.

This repository holds only what a provider needs to **download and run** the
agent: the installer and the released binaries. No source, no secrets.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/zeroserver-cc/zsc-agent-runner/main/install.sh | sh
```

This downloads the standalone `zsc-agent` binary for your OS/architecture,
verifies its checksum, fetches the matching `frpc`, installs it to
`/usr/local/bin/zsc-agent`, and registers it as a service (systemd on Linux,
launchd on macOS). No Node.js required. The installer is idempotent — re-run it
to upgrade.

Supported targets: `linux/x64`, `linux/arm64`, `macos/arm64`.

### Options

Set as environment variables before the command:

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `ZSC_AGENT_VERSION` | latest | Release tag to install |
| `ZSC_AGENT_INSTALL_DIR` | `/usr/local/bin` | Binary install dir |
| `ZSC_AGENT_LIB_DIR` | `/usr/local/lib/zsc-agent` | Where `frpc` is placed |
| `ZSC_AGENT_NO_SERVICE` | — | Set to `1` to skip the service install |
| `FRP_VERSION` | `0.61.1` | `frpc` version to fetch |

## Requirements

- A Linux or macOS host with **Docker** installed and running.
- Outbound network access (the agent connects out; no inbound ports or public IP
  needed — it reaches the cloud through an outbound tunnel).

## After installing

On first run the agent prints a **machine claim token**. Enter that token in the
provider portal to attach the machine to your account. Until claimed, the machine
reports telemetry but receives no workloads.

## Keeping the node clean

The agent periodically prunes dangling Docker images and build cache so the disk
doesn't fill up over time. It never removes your containers or volumes. Tune it
with `ZSC_PRUNE_ENABLED`, `ZSC_PRUNE_INTERVAL_MS`, and `ZSC_PRUNE_ALL_IMAGES`.

## Uninstall

Detach the machine from your account, stop the service, and remove the files:

```sh
zsc-agent deregister

# Linux (systemd)
sudo systemctl disable --now zsc-agent

# macOS (launchd)
sudo launchctl bootout system /Library/LaunchDaemons/cc.zeroserver.agent.plist 2>/dev/null || true

sudo rm -f /usr/local/bin/zsc-agent /usr/local/lib/zsc-agent/frpc
```

---

The agent is part of the ZSC platform, built on open-source values and
community-first principles. Binaries are published here from the ZSC build
pipeline; checksums accompany every release.
