import ipaddress
import sys

print(sys.argv)

if len(sys.argv) != 4:
    raise Exception("prepare_network.py requires exactly 3 arguments")

net_type = sys.argv[1]
net_range = sys.argv[2]
out_file = sys.argv[3]

net_required_ranges = {
    'pxe': {
        'NETWORK_PXE_BRIDGE_IP': 1,
        'NETWORK_PXE_DHCP_RANGE': 10,
        'NETWORK_PXE_STATIC_RANGE_MGMT': 3,
        'NETWORK_PXE_METALLB_RANGE': 5
    },
    'lcm': {
        'NETWORK_LCM_SEED_IP': 1,
        'NETWORK_LCM_MGMT_LB_HOST': 1,
        'NETWORK_LCM_METALLB_RANGE_MGMT': 15,
        'NETWORK_LCM_MANAGED_LB_HOST': 1,
        'NETWORK_LCM_STATIC_RANGE_MGMT': 3,
        'NETWORK_LCM_METALLB_RANGE_MANAGED': 7,
        'NETWORK_LCM_STATIC_RANGE_MANAGED': 7,
        'NETWORK_LCM_METALLB_OPENSTACK_ADDRESS': 1
    }
}

if not net_required_ranges.get(net_type, False):
    raise Exception(f"unknown network type is provided: {net_type}")

required_num_ips = 0
for _, v in net_required_ranges[net_type].items():
    required_num_ips += v

net_range_start, net_range_end = net_range.split('-')[0], net_range.split('-')[1]
ranges = ipaddress.summarize_address_range(ipaddress.IPv4Address(net_range_start),
                                           ipaddress.IPv4Address(net_range_end))
addresses = []
for ir in ranges:
    for ip in ir:
        addresses.append(ip)

if len(addresses) < required_num_ips:
    raise Exception("Not enough IP addresses for deployment."
                    f"Required: {required_num_ips}. Provided: {len(addresses)}")

result = {}
cur_index = 0
for item, amount in net_required_ranges[net_type].items():
    if amount == 1:
        result[item] = str(addresses[cur_index])
    else:
        result[item] = str(f"{addresses[cur_index]}-{addresses[cur_index+amount-1]}")

    cur_index += amount

f = open(out_file, 'w')
for k, v in result.items():
    f.write(f"export {k}={v}\n")
f.close()

print(f"Ranges for {net_type} network were generated successfully")
