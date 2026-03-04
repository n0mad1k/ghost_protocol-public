# OPSEC Checklist

## Pre-Session Setup
- [ ] Fresh VM snapshot taken
- [ ] MAC address randomized: `randomize-mac`
- [ ] System timezone set appropriately
- [ ] DNS configured for privacy
- [ ] Verify no personal accounts logged in
- [ ] Disable WiFi/Bluetooth if not needed
- [ ] Configure VPN/proxy settings
- [ ] Test kill switches

## During Session
- [ ] Use workspace isolation (separate VM/container)
- [ ] All traffic through VPN/Tor
- [ ] Monitor connections: `opsec-monitor`
- [ ] Use encrypted communications
- [ ] No personal browsing/email
- [ ] Regular history clearing
- [ ] Avoid saving sensitive data locally
- [ ] Use in-memory tools when possible

## Post-Session
- [ ] Export necessary data
- [ ] Clear all logs: `clear-logs`
- [ ] Clear shell history: `clear-history`
- [ ] Wipe free space
- [ ] Secure delete files: `shred-file <files>`
- [ ] Revert to clean VM snapshot

## Emergency Procedures
- [ ] Kill network connections
- [ ] Emergency wipe if necessary

## Communication OPSEC
- [ ] Use encrypted channels
- [ ] Avoid real names/identifiers
- [ ] Use dedicated accounts
- [ ] Regular key rotation
