# Hallon - Raspberry Pi Home Automation Setup

This folder contains the configuration for running Zigbee2MQTT on a Raspberry Pi 3B+ with ConBee USB stick.

## Architecture

```
┌─────────────────────┐
│   Raspberry Pi      │
│   - Zigbee2MQTT     │──USB──> ConBee II ──Zigbee──> Devices
│   (Docker)          │
└──────────┬──────────┘
           │ MQTT
           │
┌──────────▼──────────┐
│   K3s Cluster       │
│   - Mosquitto MQTT  │
│   - Home Assistant  │
└─────────────────────┘
```

## Components

### On Raspberry Pi (via Docker)
- **Zigbee2MQTT**: Bridges Zigbee devices to MQTT

### On K3s Cluster (via Flux GitOps)
- **Mosquitto**: MQTT broker
- **Home Assistant**: Home automation platform

## Prerequisites

- Raspberry Pi 3B+ (or newer) with Raspberry Pi OS
- ConBee II USB stick plugged into the Pi
- SSH access to the Pi
- Ansible installed on your local machine

## Setup Instructions

### 1. Configure Inventory

Edit `ansible/inventory.yml` and set your Pi's IP address:

```yaml
ansible_host: 192.168.0.XXX  # Your Pi's IP
ansible_user: pi              # Your Pi username
```

### 2. Configure Variables

Edit `ansible/group_vars/raspberry_pi.yml`:

```yaml
mosquitto_host: 192.168.0.200  # Your Mosquitto LoadBalancer IP (check with: kubectl get svc -n mqtt)
timezone: Europe/Stockholm      # Your timezone
```

### 3. Deploy with Ansible

From the `hallon` directory:

```bash
# Test connection
ansible -i ansible/inventory.yml raspberry_pi -m ping

# Run the playbook
ansible-playbook -i ansible/inventory.yml ansible/playbook.yml
```

### 4. Verify Deployment

Check if Zigbee2MQTT is running:

```bash
ssh pi@<your-pi-ip>
docker ps
docker logs zigbee2mqtt
```

Access Zigbee2MQTT frontend: `http://<pi-ip>:8080`

### 5. Connect to Home Assistant

The MQTT integration should automatically discover Zigbee2MQTT devices in Home Assistant.

1. Go to Home Assistant: `http://<your-ha-url>:8123`
2. Navigate to Settings → Devices & Services
3. MQTT integration should show discovered Zigbee devices

## Mosquitto MQTT Broker

The Mosquitto MQTT broker runs in your k3s cluster and is deployed via Flux.

### Check Mosquitto Status

```bash
# Get Mosquitto service IP
kubectl get svc -n mqtt mosquitto

# Check logs
kubectl logs -n mqtt -l app=mosquitto

# Test MQTT connection from Pi
mosquitto_sub -h <mosquitto-ip> -t 'zigbee2mqtt/#' -v
```

## Maintenance

### Update Zigbee2MQTT

```bash
cd /opt/zigbee2mqtt
docker-compose pull
docker-compose up -d
```

### View Logs

```bash
# Real-time logs
docker logs -f zigbee2mqtt

# Last 100 lines
docker logs --tail 100 zigbee2mqtt
```

### Restart Service

```bash
sudo systemctl restart zigbee2mqtt
```

### Add New Zigbee Devices

1. Open Zigbee2MQTT frontend: `http://<pi-ip>:8080`
2. Click "Permit join (All)" button
3. Put your Zigbee device in pairing mode
4. Device should appear in the frontend within 30 seconds

## Troubleshooting

### ConBee not detected

Check if the device is visible:

```bash
ls -l /dev/ttyACM*
dmesg | grep tty
```

### MQTT connection issues

Test MQTT connectivity:

```bash
# Install mosquitto clients on Pi
sudo apt install mosquitto-clients

# Test connection
mosquitto_pub -h <mosquitto-ip> -t test -m "hello"
mosquitto_sub -h <mosquitto-ip> -t test
```

### Check Docker logs

```bash
docker logs zigbee2mqtt --tail 50
```

## Configuration Files

- `ansible/playbook.yml`: Ansible playbook for Pi setup
- `ansible/inventory.yml`: Pi host configuration
- `ansible/group_vars/raspberry_pi.yml`: Variables for deployment
- `docker-compose.yml`: Docker Compose template
- `zigbee2mqtt/configuration.yaml`: Zigbee2MQTT config template

## Security Considerations

### Enable MQTT Authentication (Recommended for Production)

1. Edit `kubernetes/components/mosquitto/configmap.yaml`:
   ```yaml
   allow_anonymous false
   password_file /mosquitto/config/passwd
   ```

2. Create password file in k3s and mount it

3. Update `zigbee2mqtt/configuration.yaml` with credentials

### Firewall Rules

Ensure only necessary ports are exposed:
- Pi: 8080 (Zigbee2MQTT frontend) - restrict to local network
- Mosquitto: 1883 (MQTT) - internal cluster traffic only

## Additional Services Ideas for Raspberry Pi

### Hardware-Dependent Services

1. **RTL-SDR Radio Scanner**
   - Software Defined Radio for monitoring radio frequencies
   - Use case: Weather station data, ADS-B aircraft tracking
   - Resource: Low

2. **Bluetooth Presence Detection**
   - Monitor Bluetooth devices for home/away automation
   - Use case: Room presence, device tracking
   - Resource: Very low

3. **IR Blaster Controller**
   - Control infrared devices (TV, AC, etc.)
   - Requires: IR LED hardware
   - Resource: Very low

### Network/Edge Services

4. **ESPHome Dashboard**
   - Manage ESP32/ESP8266 devices
   - Use case: Flash and configure ESPHome devices
   - Resource: Low

5. **Node-RED**
   - Visual automation flows
   - Use case: Complex automation logic
   - Resource: Low-Medium

6. **AdGuard Home / Pi-hole**
   - DNS-level ad blocking (you already have Pi-hole in k3s)
   - Could be backup/secondary instance
   - Resource: Low

7. **Network UPS Tools (NUT)**
   - UPS monitoring if Pi is connected to UPS
   - Use case: Safe shutdown on power loss
   - Resource: Very low

### Recommended for Your Setup

Given the Pi 3B+ resources and your existing setup, I recommend:

**Currently Implemented:**
✅ Zigbee2MQTT - Essential for your ConBee stick

**Good Additions:**
1. **Bluetooth Proxy for Home Assistant**
   - Extends Bluetooth range for HA
   - Very lightweight
   - Works well alongside Zigbee2MQTT

2. **ESPHome Dashboard**
   - If you plan to use ESP32 devices
   - Complements Zigbee setup

**Maybe Later:**
- Node-RED (can run in k3s instead if needed)
- NUT (if Pi is on UPS)

**Avoid:**
- Heavy services (databases, media servers)
- Anything with high CPU usage
- Services better suited for k3s cluster

## Links

- [Zigbee2MQTT Documentation](https://www.zigbee2mqtt.io/)
- [ConBee II Documentation](https://phoscon.de/en/conbee2)
- [Mosquitto Documentation](https://mosquitto.org/documentation/)
- [Home Assistant Zigbee Integration](https://www.home-assistant.io/integrations/mqtt/)
