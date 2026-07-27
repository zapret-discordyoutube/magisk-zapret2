# Owner metadata schema v9

Schema v9 adds `tethering` to the authenticated firewall generation. It is the
canonical `0`/`1` capture-topology decision copied from `runtime.ini [core]`,
and it participates in the per-family specification and firewall fingerprint.

A tethered generation anchors both owned chains a second time, into
`mangle FORWARD`, so traffic forwarded to devices on the phone's hotspot meets
the same rules the local traffic does. It publishes no additional chain and no
additional rule: a forwarded request is the same conntrack original direction
with the server port as destination, and its reply is the same reply direction
with the server port as source. Because the field is part of the record, health
verification re-verifies a live generation against the topology it published
rather than the one currently configured, and a changed setting becomes a
topology replacement instead of a health failure. Teardown answers to the
baseline it captured, so anchors published by a tethered generation are removed
even after the setting has been turned off.

Schema v8 made the compiled preset capture policy part of the authenticated
firewall generation through four fields:

- `tcp_pkt_out`
- `tcp_pkt_in`
- `udp_pkt_out`
- `udp_pkt_in`

All four are canonical positive decimal packet bounds copied from the active
TXT preset by `command-builder.sh`. They participate in the per-family
specification and firewall fingerprint. Start, health verification, teardown,
and rollback therefore use the same protocol-specific values;
none may read a competing runtime or Android setting.

The schema also binds the command SHA-256, boot identity, stable
`ZAPRET2_OUT`/`ZAPRET2_IN` namespace, exact port unions, capability flags, rule
counts, family specifications, and fingerprint. Health verification projects
that bounded receipt through the same reconciler that publishes the direct
chain rules. There are no generation-bound payload chains or firewall WAL.
Runtime code recognizes and publishes only v9; package replacement starts a
fresh generation after the mandatory reboot.
