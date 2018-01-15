# Merge EC2 ephemeral disks
Some of the EC2 instance-types provide ephemeral SSD drives coming built-in with the instance for no additional cost. We can combine them using software RAID.

This script will discover all ephemeral drives on an EC2 node
and merge them to a "single" big disk using RAID-0 stripe.

Execute it on first system boot, as user-data script.

### EC2 Instance types supported
 - C (compute-intensive)

# Required Packages
The following packages should be installed:
`curl`
`mdadm`
