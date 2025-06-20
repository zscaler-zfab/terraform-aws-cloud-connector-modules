################################################################################
# Network Infrastructure Resources
################################################################################
# Identify availability zones available for region selected
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}


################################################################################
# VPC
################################################################################
# Create a new VPC
resource "aws_vpc" "vpc" {
  count                = var.byo_vpc == false ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-vpc-${var.resource_tag}" }
  )
}

# Or reference an existing VPC
data "aws_vpc" "vpc_selected" {
  count = var.byo_vpc ? 1 : 0
  id    = var.byo_vpc_id
}


################################################################################
# Internet Gateway
################################################################################
# Create an Internet Gateway
resource "aws_internet_gateway" "igw" {
  count  = var.byo_igw == false ? 1 : 0
  vpc_id = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-igw-${var.resource_tag}" }
  )
}

# Or reference an existing Internet Gateway
data "aws_internet_gateway" "igw_selected" {
  internet_gateway_id = var.byo_igw == false ? aws_internet_gateway.igw[0].id : var.byo_igw_id
}


################################################################################
# NAT Gateway
################################################################################
# Create NAT Gateway and assign EIP per AZ. This will not be created if var.byo_ngw is set to True
resource "aws_eip" "eip" {
  count      = var.byo_ngw == false ? length(aws_subnet.public_subnet[*].id) : 0
  depends_on = [data.aws_internet_gateway.igw_selected]

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-eip-az${count.index + 1}-${var.resource_tag}" }
  )
}

# Create 1 NAT Gateway per Public Subnet.
resource "aws_nat_gateway" "ngw" {
  count         = var.byo_ngw == false ? length(aws_subnet.public_subnet[*].id) : 0
  allocation_id = aws_eip.eip[count.index].id
  subnet_id     = aws_subnet.public_subnet[count.index].id
  depends_on    = [data.aws_internet_gateway.igw_selected]

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-natgw-az${count.index + 1}-${var.resource_tag}" }
  )
}

# Or reference existing NAT Gateways
data "aws_nat_gateway" "ngw_selected" {
  count = var.byo_ngw == false ? length(aws_nat_gateway.ngw[*].id) : length(var.byo_ngw_ids)
  id    = var.byo_ngw == false ? aws_nat_gateway.ngw[count.index].id : element(var.byo_ngw_ids, count.index)
}


################################################################################
# Public (NAT Gateway) Subnet & Route Tables
################################################################################
# Create equal number of Public/NAT Subnets to how many Cloud Connector subnets exist. This will not be created if var.byo_ngw is set to True
resource "aws_subnet" "public_subnet" {
  count             = var.byo_ngw == false ? length(data.aws_subnet.cc_subnet_selected[*].id) : 0
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = var.public_subnets != null ? element(var.public_subnets, count.index) : cidrsubnet(try(data.aws_vpc.vpc_selected[0].cidr_block, aws_vpc.vpc[0].cidr_block), 8, count.index + 101)
  vpc_id            = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-public-subnet-${count.index + 1}-${var.resource_tag}" }
  )
}


# Create a public Route Table towards IGW. This will not be created if var.byo_ngw is set to True
resource "aws_route_table" "public_rt" {
  count  = var.byo_ngw == false ? 1 : 0
  vpc_id = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags, {
    Name = "${var.name_prefix}-public-rt-${var.resource_tag}"
  })
}

resource "aws_route" "public_rt_default_route" {
  count = var.byo_ngw == false ? 1 : 0

  route_table_id         = aws_route_table.public_rt[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.igw_selected.internet_gateway_id
}



# Create equal number of Route Table associations to how many Public subnets exist. This will not be created if var.byo_ngw is set to True
resource "aws_route_table_association" "public_rt_association" {
  count          = var.byo_ngw == false ? length(aws_subnet.public_subnet[*].id) : 0
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_rt[0].id
}


################################################################################
# Private (Workload) Subnet & Route Tables
################################################################################
# Create equal number of Workload/Private Subnets to how many Cloud Connector subnets exist. This will not be created if var.workloads_enabled is set to False
resource "aws_subnet" "workload_subnet" {
  count             = var.workloads_enabled == true ? length(data.aws_subnet.cc_subnet_selected[*].id) : 0
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = var.workloads_subnets != null ? element(var.workloads_subnets, count.index) : cidrsubnet(try(data.aws_vpc.vpc_selected[0].cidr_block, aws_vpc.vpc[0].cidr_block), 8, count.index + 1)
  vpc_id            = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-workload-subnet-${count.index + 1}-${var.resource_tag}" }
  )
}

# Create Route Table for private subnets (workload servers) towards CC Service ENI or GWLB Endpoint depending on deployment type
resource "aws_route_table" "workload_rt" {
  count  = length(aws_subnet.workload_subnet[*].id)
  vpc_id = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags, {
    Name = "${var.name_prefix}-workload-to-cc-${count.index + 1}-rt-${var.resource_tag}"
  })
}

resource "aws_route" "workload_rt_gwlb" {
  count = var.gwlb_enabled ? length(aws_subnet.workload_subnet[*].id) : 0

  route_table_id    = aws_route_table.workload_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id   = element(var.gwlb_endpoint_ids, count.index)
}

resource "aws_route" "workload_rt_eni" {
  count = var.gwlb_enabled == false && var.base_only == false ? length(aws_subnet.workload_subnet[*].id) : 0

  route_table_id         = aws_route_table.workload_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = element(var.cc_service_enis, count.index)
}

resource "aws_route" "workload_rt_nat" {
  count = var.base_only == true ? length(aws_subnet.workload_subnet[*].id) : 0

  route_table_id         = aws_route_table.workload_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = element(data.aws_nat_gateway.ngw_selected[*].id, count.index)
}

# Create Workload Route Table Association
resource "aws_route_table_association" "workload_rt_association" {
  count          = length(aws_subnet.workload_subnet[*].id)
  subnet_id      = aws_subnet.workload_subnet[count.index].id
  route_table_id = aws_route_table.workload_rt[count.index].id
}


################################################################################
# Private (Cloud Connector) Subnet & Route Tables
################################################################################
# Create subnet for CC network in X availability zones per az_count variable
resource "aws_subnet" "cc_subnet" {
  count = var.byo_subnets == false ? var.az_count : 0

  availability_zone                           = data.aws_availability_zones.available.names[count.index]
  cidr_block                                  = var.cc_subnets != null ? element(var.cc_subnets, count.index) : cidrsubnet(try(data.aws_vpc.vpc_selected[0].cidr_block, aws_vpc.vpc[0].cidr_block), 8, count.index + 200)
  vpc_id                                      = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)
  enable_resource_name_dns_a_record_on_launch = var.resource_name_dns_a_record_enabled
  private_dns_hostname_type_on_launch         = var.hostname_type

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-cc-subnet-${count.index + 1}-${var.resource_tag}" }
  )
}

# Or reference existing subnets
data "aws_subnet" "cc_subnet_selected" {
  count = var.byo_subnets == false ? var.az_count : length(var.byo_subnet_ids)
  id    = var.byo_subnets == false ? aws_subnet.cc_subnet[count.index].id : element(var.byo_subnet_ids, count.index)
}


# Create Route Tables for CC subnets pointing to NAT Gateway resource in each AZ or however many were specified. Optionally, point directly to IGW for public deployments
resource "aws_route_table" "cc_rt" {
  count  = var.cc_route_table_enabled ? length(data.aws_subnet.cc_subnet_selected[*].id) : 0
  vpc_id = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags, {
    Name = "${var.name_prefix}-cc-rt-${count.index + 1}-${var.resource_tag}"
  })
}

resource "aws_route" "cc_rt_route" {
  count = var.cc_route_table_enabled ? length(data.aws_subnet.cc_subnet_selected[*].id) : 0

  route_table_id         = aws_route_table.cc_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = element(data.aws_nat_gateway.ngw_selected[*].id, count.index)
}

# CC subnet Route Table Association
resource "aws_route_table_association" "cc_rt_asssociation" {
  count          = var.cc_route_table_enabled ? length(data.aws_subnet.cc_subnet_selected[*].id) : 0
  subnet_id      = data.aws_subnet.cc_subnet_selected[count.index].id
  route_table_id = aws_route_table.cc_rt[count.index].id
}


################################################################################
# Private (Route 53 Endpoint) Subnet & Route Tables
################################################################################
# Optional Route53 subnet creation for ZPA
# Create Route53 reserved subnets in X availability zones per az_count variable or minimum of 2; whichever is greater
resource "aws_subnet" "route53_subnet" {
  count             = var.zpa_enabled && length(var.byo_r53_subnet_ids) == 0 ? max(length(data.aws_subnet.cc_subnet_selected[*].id), 2) : 0
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = var.route53_subnets != null ? element(var.route53_subnets, count.index) : cidrsubnet(try(data.aws_vpc.vpc_selected[0].cidr_block, aws_vpc.vpc[0].cidr_block), 12, (64 + count.index * 16))
  vpc_id            = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags,
    { Name = "${var.name_prefix}-route53-subnet-${count.index + 1}-${var.resource_tag}" }
  )
}

# Or reference existing subnets
data "aws_subnet" "route53_subnet_selected" {
  count = var.zpa_enabled && length(var.byo_r53_subnet_ids) != 0 ? length(var.byo_r53_subnet_ids) : 0
  id    = element(var.byo_r53_subnet_ids, count.index)
}


# Create Route Table for Route53 routing to GWLB Endpoint in the same AZ for DNS redirection
resource "aws_route_table" "route53_rt" {
  count = var.zpa_enabled && var.r53_route_table_enabled ? length(coalescelist(data.aws_subnet.route53_subnet_selected[*].id, aws_subnet.route53_subnet[*].id)) : 0

  vpc_id = try(data.aws_vpc.vpc_selected[0].id, aws_vpc.vpc[0].id)

  tags = merge(var.global_tags, {
    Name = "${var.name_prefix}-route53-to-cc-${count.index + 1}-rt-${var.resource_tag}"
  })
}

resource "aws_route" "route53_rt_gwlb" {
  count = var.zpa_enabled && var.r53_route_table_enabled && var.gwlb_enabled ? length(coalescelist(data.aws_subnet.route53_subnet_selected[*].id, aws_subnet.route53_subnet[*].id)) : 0

  route_table_id         = aws_route_table.route53_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = element(var.gwlb_endpoint_ids, count.index)
}

resource "aws_route" "route53_rt_eni" {
  count = var.zpa_enabled && var.r53_route_table_enabled && !var.gwlb_enabled ? length(coalescelist(data.aws_subnet.route53_subnet_selected[*].id, aws_subnet.route53_subnet[*].id)) : 0

  route_table_id         = aws_route_table.route53_rt[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = element(var.cc_service_enis, count.index)
}

# Route53 Subnets Route Table Assocation
resource "aws_route_table_association" "route53_rt_asssociation" {
  count          = var.zpa_enabled == true ? length(aws_subnet.route53_subnet[*].id) : 0
  subnet_id      = try(data.aws_subnet.route53_subnet_selected[count.index].id, aws_subnet.route53_subnet[count.index].id)
  route_table_id = aws_route_table.route53_rt[count.index].id
}
