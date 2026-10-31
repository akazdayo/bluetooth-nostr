# BLE exchange protocol, version 1

This is an application-specific transport, not a NIP-01 WebSocket relay. NIP-01 event JSON, event IDs, and signatures are unchanged. Any nearby compatible device can read and retransmit shared events. This protocol does not provide confidentiality or peer authentication.

The service UUID is `A0F0F130-6A39-4A1A-9B2B-E491C14465A0`. A central writes to characteristic `A0F0F131-6A39-4A1A-9B2B-E491C14465A0` with response, and subscribes to notifications on `A0F0F132-6A39-4A1A-9B2B-E491C14465A0`. Each direction is an independent byte stream; chunks use the Core Bluetooth negotiated limits. A message is a four-byte big-endian payload length followed by UTF-8 JSON. The payload limit is 65,536 bytes.

Each message has `version: 1` and a `type`: `inventory` contains `ids`, `request` contains missing `ids`, and `event` contains a single signed event in `events`. Each endpoint sends inventories on subscription and when its store changes. Receivers validate the event ID and signature and persist before exposing or forwarding it; IDs deduplicate events. Failed or interrupted transfers can be requested again after reconnection.

The current implementation shares at most the newest 256 events whose JSON representation is at most 16,384 bytes. IDs are batched in groups of at most 256; outbound queued data is bounded to 8 MiB per peer and up to eight peers are supported in each role. It is a prototype: background discovery, actual transfer reliability, and throughput require testing on physical devices. It does not implement the NIP-01 relay WebSocket protocol or a general Nostr subscription interface.
