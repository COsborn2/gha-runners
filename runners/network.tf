# A small VPC with public subnets only. Runners get a public IPv4 address and
# reach GitHub, package mirrors and AWS APIs through the internet gateway, so
# there is no NAT gateway (~$33/month before traffic). Nothing can connect in:
# the runner security group the module creates has no ingress rules.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # regular AZs only, no Local/Wavelength Zones
  }
}

locals {
  # Spot capacity is tracked per AZ; spreading over three gives EC2 Fleet
  # more pools to choose from.
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
}

resource "aws_vpc" "runners" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.prefix}-runners"
  }
}

resource "aws_internet_gateway" "runners" {
  vpc_id = aws_vpc.runners.id

  tags = {
    Name = "${var.prefix}-runners"
  }
}

resource "aws_subnet" "public" {
  for_each = { for index, az in local.availability_zones : az => index }

  vpc_id                  = aws_vpc.runners.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(aws_vpc.runners.cidr_block, 4, each.value) # /20: 4,091 addresses each
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.prefix}-runners-${each.key}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.runners.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.runners.id
  }

  tags = {
    Name = "${var.prefix}-runners-public"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
