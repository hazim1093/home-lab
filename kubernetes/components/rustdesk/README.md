# RustDesk Server Setup

RustDesk is a self-hosted remote desktop solution that allows you to access your computers from anywhere.

## Server Details

- **Namespace**: `rustdesk`
- **Service IP**: `192.168.0.203`
- **DNS Name**: `rustdesk.lab`
- **Helm Chart**: `pschichtel/rustdesk-server-oss` v0.2.3

## Required Ports

- **21115** (TCP) - NAT type test
- **21116** (TCP/UDP) - ID registration and heartbeat service
- **21117** (TCP) - Relay services
- **21118** (TCP) - Web client support (optional)
- **21119** (TCP) - WebSocket services (optional)

## Initial Setup

### 1. Get Server Public Key

```bash
kubectl debug -n rustdesk \
  $(kubectl get pod -n rustdesk -l app.kubernetes.io/name=rustdesk-server-oss -o jsonpath='{.items[0].metadata.name}') \
  -it --image=busybox --target=rustdesk-server-hbbs --share-processes \
  -- cat /proc/1/root/root/id_ed25519.pub
```

Save this key - all clients need it to connect.

## Client Configuration

### Desktop (Mac/Windows/Linux)

1. Download RustDesk from https://rustdesk.com/
2. Install and open the application
3. Click the menu icon (⋯) → **Settings**
4. Navigate to **Network** tab
5. Configure:
   - **ID Server**: `rustdesk.lab` or `192.168.0.203`
   - **Relay Server**: `rustdesk.lab` or `192.168.0.203`
   - **API Server**: Leave blank (optional)
   - **Key**: Paste your server's public key
6. Click **Apply**
7. Note your device's RustDesk ID (displayed on main screen)

### Mobile (iOS/Android)

1. Install RustDesk from App Store or Google Play
2. Open the app
3. Tap **Settings** (gear icon)
4. Tap **ID/Relay Server**
5. Configure:
   - **ID Server**: `192.168.0.203` (use IP on mobile)
   - **Relay Server**: `192.168.0.203`
   - **Key**: Paste your server's public key
6. Tap **OK** or **Save**

## Connecting to a Computer

### From Another Device

1. Ensure both devices are configured to use your RustDesk server
2. Open RustDesk on the device you want to connect FROM
3. Enter the **RustDesk ID** of the target computer
4. Click **Connect**
5. On first connection:
   - The target computer will show a popup
   - Accept the connection
   - Note the one-time password shown
6. Enter the password on the connecting device
7. You should now see the remote screen

### Setting a Permanent Password (Optional)

On the computer you want to access:
1. Open RustDesk
2. Click the lock icon next to "Your Password"
3. Set a permanent password
4. Now you can connect without accepting each time

## Troubleshooting

### Connection Issues

```bash
# Test connectivity to the server
nc -zv 192.168.0.203 21116
nc -zuv 192.168.0.203 21116

# Check if service has correct external IP
kubectl get svc -n rustdesk -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Verify MetalLB assigned the IP
kubectl describe svc -n rustdesk | grep "LoadBalancer Ingress"
```

### View Server Logs

```bash
# ID/Registry server logs (hbbs)
kubectl logs -n rustdesk -l app.kubernetes.io/name=rustdesk-server-oss -c rustdesk-server-hbbs --tail=50

# Relay server logs (hbbr)
kubectl logs -n rustdesk -l app.kubernetes.io/name=rustdesk-server-oss -c rustdesk-server-hbbr --tail=50

# Follow logs in real-time
kubectl logs -n rustdesk -l app.kubernetes.io/name=rustdesk-server-oss -c rustdesk-server-hbbs -f
```

### Check Persistent Storage

```bash
# Verify PVC is bound
kubectl get pvc -n rustdesk

# Should show:
# NAME            STATUS   VOLUME                                     CAPACITY
# rustdesk-data   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi
```

### Common Issues

**"Invalid Key" Error**
- Verify you copied the complete public key
- Key should be a long string without line breaks
- Re-check the key matches exactly what's on the server

**"Connection Failed"**
- Ensure both devices are on the same network (or port forwarding is configured)
- Verify DNS resolution: `nslookup rustdesk.lab`
- Check firewall rules aren't blocking ports 21115-21119

**Device Not Showing Up**
- Verify client is configured with correct server address
- Check the client has internet/network connectivity
- Restart RustDesk client application
- Verify the public key is correctly entered

## Security Considerations

1. **Public Key**: Keep your server's public key secure. Anyone with this key can configure clients to use your server.

2. **Network Access**: RustDesk is exposed on your local network (192.168.0.203). For remote access:
   - Configure port forwarding on your router for ports 21115-21119
   - Consider using a VPN instead of direct exposure
   - Use strong passwords on all devices

3. **Persistent Storage**: Connection data and keys are stored in the PVC. Back up if needed:
   ```bash
   kubectl exec -n rustdesk <pod-name> -c rustdesk-server-hbbs -- tar czf - /root | tar xzf -
   ```

## Remote Access (Outside Home Network)

To access your computers from outside your home network:

### Option 1: VPN (Recommended)
- Connect to your home VPN first
- Then use RustDesk as normal with `192.168.0.203` or `rustdesk.lab`

### Option 2: Port Forwarding
1. Configure port forwarding on your router:
   - External ports: 21115-21119 (TCP and UDP)
   - Internal IP: 192.168.0.203
2. Use your public IP or dynamic DNS hostname as the server address
3. **Warning**: This exposes your RustDesk server to the internet

## Maintenance

### Update RustDesk Server

Edit the chart version in `helmrelease.yaml`:
```yaml
chart:
  spec:
    version: "0.2.3"  # Update this version
```

Commit and push. Flux will automatically update the deployment.

### Restart Server

```bash
kubectl rollout restart deployment -n rustdesk
```

### View Resource Usage

```bash
kubectl top pods -n rustdesk
```

## Additional Resources

- Official Documentation: https://rustdesk.com/docs/
- RustDesk GitHub: https://github.com/rustdesk/rustdesk
- Helm Chart Source: https://github.com/pschichtel/helm-charts
