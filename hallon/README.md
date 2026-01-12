# Hallon - Raspberry Pi Zigbee2MQTT

> Zigbee2MQTT on Pi 3B+ with ConBee USB → MQTT (mqtt.lab) → Home Assistant (k3s)

## Quick Deploy

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbook.yml
```

**Frontend**: `http://<pi-ip>:8080`

## Key Info

- **MQTT Broker**: `mqtt.lab` (192.168.0.202, runs in k3s)
- **ConBee Device**: `/dev/ttyACM0`
- **Service**: `sudo systemctl restart zigbee2mqtt`

## Common Commands

```bash
# Logs
docker logs -f zigbee2mqtt

# Update
cd /opt/zigbee2mqtt && docker-compose pull && docker-compose up -d

# Test MQTT
mosquitto_sub -h mqtt.lab -t 'zigbee2mqtt/#' -v

# Check ConBee
ls -l /dev/ttyACM*
```

## Files

- `ansible/inventory.yml` - Pi IP/user
- `ansible/group_vars/raspberry_pi.yml` - MQTT host, timezone
- `docker-compose.yml` - Container config
- `zigbee2mqtt/configuration.yaml` - Z2M config
