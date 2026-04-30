#!/bin/sh

if test -f "/etc/fck-nat.conf"; then
    echo "Found fck-nat configuration at /etc/fck-nat.conf"
    . /etc/fck-nat.conf
else
    echo "No fck-nat configuration at /etc/fck-nat.conf"
fi

. /usr/local/lib/aws-utils.sh

token="$(get_imds_token)"
instance_id=$(get_instance_id $token)
aws_region="$(get_region $token)"
outbound_mac=$(imds "$token" "mac" 2>/dev/null)
outbound_eni_id=$(imds "$token" "network/interfaces/macs/$outbound_mac/interface-id" 2>/dev/null)
nat_public_interface=$(ip link show dev "$outbound_eni_id" | head -n 1 | awk '{print $2}' | sed s/://g )
nat_private_interface=$nat_public_interface

if test -n "$eip_id"; then
    echo "Found eip_id configuration, associating $eip_id..."
    associate_eip $token $aws_region $eip_id $outbound_eni_id
    sleep 3
fi

if test -n "$eni_id"; then
    echo "Found eni_id configuration, attaching $eni_id..."
    disable_source_dest_check $token $aws_region $outbound_eni_id

    if ! ip link show dev "$eni_id"; then
        while ! attach_network_interface $token $aws_region $instance_id $eni_id; do
            echo "Waiting for ENI to attach..."
            sleep 5
        done
        while ! ip link show dev "$eni_id"; do
            echo "Waiting for ENI to come up..."
            sleep 1
        done
    else
        echo "$eni_id already attached, skipping ENI attachment"
    fi

    nat_private_interface=$(ip link show dev "$eni_id" | head -n 1 | awk '{print $2}' | sed s/://g )

elif test -n "$interface"; then
    echo "Found interface configuration, using $interface"
    nat_public_interface=$interface
    nat_private_interface=$nat_public_interface
else
    echo "No eni_id or interface configuration found, using default interface $nat_public_interface"
fi

if test -x "/usr/local/bin/jool"; then
    echo "Setting up NAT64..."
    if modprobe jool; then
        /usr/local/bin/jool instance flush
        /usr/local/bin/jool instance add --netfilter --pool6 64:ff9b::/96
    else
        echo "Jool kernel module failed to load, skipping NAT64 setup."
    fi
else
    echo "Jool not installed, skipping NAT64 setup."
fi

echo "Enabling IPv4 forwarding..."
sysctl -q -w net.ipv4.ip_forward=1

if test -n "$ip_local_port_range"; then
  sysctl -q -w net.ipv4.ip_local_port_range="$ip_local_port_range"
fi

echo "Enabling ip_forward..."
sysctl -q -w net.ipv4.ip_forward=1

if test -n "$nf_conntrack_max"; then
  sysctl -q -w net.netfilter.nf_conntrack_max="$nf_conntrack_max"
fi

echo "Disabling reverse path protection..."
for i in $(find /proc/sys/net/ipv4/conf/ -name rp_filter) ; do
  echo 0 > $i;
done

echo "Flushing IPv4 NAT table..."
iptables -t nat -F

echo "Adding IPv4 NAT rules..."
iptables -t nat -A POSTROUTING -o "$nat_public_interface" -j MASQUERADE -m comment --comment "NAT routing rule installed by fck-nat"

echo "Enabling IPv6 forwarding..."
sysctl -q -w net.ipv6.conf."$nat_public_interface".accept_ra=2
sysctl -q -w net.ipv6.conf."$nat_private_interface".accept_ra=2
sysctl -q -w net.ipv6.conf.all.forwarding=1

if test -n "$cwagent_enabled" && test -n "$cwagent_cfg_param_name"; then
    echo "Found cwagent_enabled and cwagent_cfg_param_name configuration, starting CloudWatch agent..."
    systemctl enable amazon-cloudwatch-agent
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "ssm:$cwagent_cfg_param_name"
fi

echo "Done!"
