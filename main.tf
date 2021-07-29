terraform {
  required_version = "~> 1.0.3"
}

locals {
  vpc_name = format("%s-vpc", var.name)
  subnets = flatten([
    for subnet in var.subnets : [
      for az in keys(subnet["availability_zone"]) : [{
        name                    = subnet["name"]
        type                    = lookup(subnet, "type", "private")
        az                      = az
        cidr_block              = subnet["availability_zone"][az]
        map_public_ip_on_launch = lookup(subnet, "map_public_ip_on_launch", "false")
        tags                    = lookup(subnet, "tags", {})
        routes                  = lookup(subnet, "routes", [])
      }]
    ]
  ])

  public_subnets = flatten([
    [for subnet in local.subnets : subnet if subnet.type == "public"]
  ])

  private_subnets = flatten([
    [for subnet in local.subnets : subnet if subnet.type == "private"]
  ])

  internal_subnets = flatten([
    [for subnet in local.subnets : subnet if subnet.type == "internal"]
  ])

  database_subnets = flatten([
    [for subnet in local.subnets : subnet if subnet.type == "database"]
  ])

  redshift_subnets = flatten([
    [for subnet in local.subnets : subnet if subnet.type == "redshift"]
  ])

  route_tables = flatten(distinct([
    for subnet in local.subnets :
    subnet["name"]
  ]))

  peers = flatten([
    for peer in var.peers : [{
      name          = peer.name
      peer_vpc_id   = peer.peer_vpc_id
      peer_owner_id = peer.peer_owner_id
      peer_region   = lookup(peer, "peer_region", "eu-west-1")
    }]
  ])

  nat_gateway_count = var.single_nat_gateway ? 1 : length(local.public_subnets)
  vpc_id            = var.vpc_id != "" ? var.vpc_id : aws_vpc.main[0].id

  tags = merge(
    var.tags,
    {
      "Vpc" = local.vpc_name
  })

}

# VPC configuration
resource "aws_vpc" "main" {
  count = var.enabled && var.vpc_id == "" ? 1 : 0

  cidr_block                     = cidrsubnet(var.cidr_block, 0, 0)
  instance_tenancy               = var.instance_tenancy
  enable_dns_support             = var.enable_dns_support
  enable_dns_hostnames           = var.enable_dns_hostnames
  enable_classiclink             = var.enable_classiclink
  enable_classiclink_dns_support = var.enable_classiclink_dns_support
  tags = merge(
    local.tags,
    {
      "Name" = local.vpc_name
    }
  )
}

resource "aws_vpc_ipv4_cidr_block_association" "main" {
  count = var.enabled && length(var.secondary_cidr) > 0 ? length(var.secondary_cidr) : 0

  vpc_id     = local.vpc_id
  cidr_block = var.secondary_cidr[count.index]
}

# VPC DHCP settings
resource "aws_vpc_dhcp_options" "main" {
  count = var.enabled && var.enable_dhcp_options ? 1 : 0

  domain_name          = var.dhcp_options_domain_name
  domain_name_servers  = var.dhcp_options_domain_name_servers
  ntp_servers          = var.dhcp_options_ntp_servers
  netbios_name_servers = var.dhcp_options_netbios_name_servers
  netbios_node_type    = var.dhcp_options_netbios_node_type
  tags = merge(
    local.tags,
    {
      "Name" = format("%s-dhcp-options", var.name)
    }
  )
}

resource "aws_vpc_dhcp_options_association" "main" {
  count = var.enabled && var.enable_dhcp_options ? 1 : 0

  vpc_id          = local.vpc_id
  dhcp_options_id = aws_vpc_dhcp_options.main[count.index].id
}

# Netowrk configuration

resource "aws_internet_gateway" "main" {
  count = var.enabled ? 1 : 0

  vpc_id = local.vpc_id
  tags = merge(
    local.tags,
    {
      "Name" = format("%s-igw", var.name)
    }
  )
}

resource "aws_eip" "main" {
  count = var.enabled && length(local.public_subnets) > 0 ? local.nat_gateway_count : 0

  vpc = true

  tags = merge(
    var.tags,
    {
      "Name" = format("%s-eip", var.name)
    }
  )
}

resource "aws_nat_gateway" "main" {
  count = var.enabled && length(local.public_subnets) > 0 ? local.nat_gateway_count : 0

  allocation_id = aws_eip.main[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(
    var.tags,
    {
      "Name" = format("%s-nat-gw", var.name)
    }
  )
}

resource "aws_route_table" "public" {
  count  = var.enabled && length(local.public_subnets) > 0 ? 1 : 0
  vpc_id = local.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.public_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "gateway_id")
      ]
    ])

    content {
      cidr_block = route.value.cidr_block
      gateway_id = route.value.gateway_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.public_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "instance_id")
      ]
    ])

    content {
      cidr_block  = route.value.cidr_block
      instance_id = route.value.instance_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.public_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "peering_id")
      ]
    ])

    content {
      cidr_block                = route.value.cidr_block
      vpc_peering_connection_id = route.value.peering_id
    }
  }

  tags = merge(
    local.tags,
    {
      "Name" = format("%s-route-table-public", var.name)
    }
  )
}

resource "aws_subnet" "public" {
  count = var.enabled && length(local.public_subnets) > 0 ? length(local.public_subnets) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = cidrsubnet(local.public_subnets[count.index].cidr_block, 0, 0)
  availability_zone       = local.public_subnets[count.index].az
  map_public_ip_on_launch = local.public_subnets[count.index].map_public_ip_on_launch
  tags = merge(merge(local.tags,
    {
      "Name"              = format("%s-subnet-%s-%s", var.name, local.public_subnets[count.index].type, local.public_subnets[count.index].az),
      "Subnet"            = local.public_subnets[count.index].name,
      "Cidr_block"        = local.public_subnets[count.index].cidr_block,
      "Availability_zone" = local.public_subnets[count.index].az,
      "Type"              = local.public_subnets[count.index].type
    }
  ), local.public_subnets[count.index].tags)
}


resource "aws_route_table_association" "public" {
  count = var.enabled && length(local.public_subnets) > 0 ? length(local.public_subnets) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count = var.enabled && length(local.private_subnets) > 0 ? 1 : 0

  vpc_id = local.vpc_id


  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.private_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "nat_gateway_id")
      ]
    ])

    content {
      cidr_block     = route.value.cidr_block
      nat_gateway_id = route.value.nat_gateway_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.private_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "instance_id")
      ]
    ])

    content {
      cidr_block  = route.value.cidr_block
      instance_id = route.value.instance_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.private_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "peering_id")
      ]
    ])

    content {
      cidr_block                = route.value.cidr_block
      vpc_peering_connection_id = route.value.peering_id
    }
  }


  tags = merge(
    local.tags,
    {
      "Name" = format("%s-route-table-private", var.name)
    }
  )
}

resource "aws_subnet" "private" {
  count = var.enabled && length(local.private_subnets) > 0 ? length(local.private_subnets) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = cidrsubnet(local.private_subnets[count.index].cidr_block, 0, 0)
  availability_zone       = local.private_subnets[count.index].az
  map_public_ip_on_launch = false
  tags = merge(merge(local.tags,
    {
      "Name"              = format("%s-subnet-%s-%s", var.name, local.private_subnets[count.index].type, local.private_subnets[count.index].az),
      "Subnet"            = local.private_subnets[count.index].name,
      "Cidr_block"        = local.private_subnets[count.index].cidr_block,
      "Availability_zone" = local.private_subnets[count.index].az,
      "Type"              = local.private_subnets[count.index].type
    }
  ), local.private_subnets[count.index].tags)
}

resource "aws_route_table_association" "private" {
  count = var.enabled && length(local.private_subnets) > 0 ? length(local.private_subnets) : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

resource "aws_route_table" "internal" {
  count = var.enabled && length(local.internal_subnets) > 0 ? 1 : 0

  vpc_id = local.vpc_id

  dynamic "route" {
    for_each = flatten([
      for subnet in local.internal_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "nat_gateway_id")
      ]
    ])

    content {
      cidr_block     = route.value.cidr_block
      nat_gateway_id = route.value.nat_gateway_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.internal_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "instance_id")
      ]
    ])

    content {
      cidr_block  = route.value.cidr_block
      instance_id = route.value.instance_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.internal_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "peering_id")
      ]
    ])

    content {
      cidr_block                = route.value.cidr_block
      vpc_peering_connection_id = route.value.peering_id
    }
  }

  tags = merge(
    local.tags,
    {
      "Name" = format("%s-route-table-internal", var.name)
    }
  )
}

resource "aws_subnet" "internal" {
  count = var.enabled && length(local.internal_subnets) > 0 ? length(local.internal_subnets) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = cidrsubnet(local.internal_subnets[count.index].cidr_block, 0, 0)
  availability_zone       = local.internal_subnets[count.index].az
  map_public_ip_on_launch = false
  tags = merge(merge(local.tags,
    {
      "Name"              = format("%s-subnet-%s-%s", var.name, local.internal_subnets[count.index].type, local.internal_subnets[count.index].az),
      "Subnet"            = local.internal_subnets[count.index].name,
      "Cidr_block"        = local.internal_subnets[count.index].cidr_block,
      "Availability_zone" = local.internal_subnets[count.index].az,
      "Type"              = local.internal_subnets[count.index].type
    }
  ), local.internal_subnets[count.index].tags)
}

resource "aws_route_table_association" "internal" {
  count = var.enabled && length(local.internal_subnets) > 0 ? length(local.internal_subnets) : 0

  subnet_id      = aws_subnet.internal[count.index].id
  route_table_id = aws_route_table.internal[0].id
}

resource "aws_route_table" "database" {
  count = var.enabled && length(local.database_subnets) > 0 ? 1 : 0

  vpc_id = local.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.database_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "nat_gateway_id")
      ]
    ])

    content {
      cidr_block     = route.value.cidr_block
      nat_gateway_id = route.value.nat_gateway_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.database_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "instance_id")
      ]
    ])

    content {
      cidr_block  = route.value.cidr_block
      instance_id = route.value.instance_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.database_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "peering_id")
      ]
    ])

    content {
      cidr_block                = route.value.cidr_block
      vpc_peering_connection_id = route.value.peering_id
    }
  }

  tags = merge(
    local.tags,
    {
      "Name" = format("%s-route-table-database", var.name)
    }
  )
}

resource "aws_subnet" "database" {
  count = var.enabled && length(local.database_subnets) > 0 ? length(local.database_subnets) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = cidrsubnet(local.database_subnets[count.index].cidr_block, 0, 0)
  availability_zone       = local.database_subnets[count.index].az
  map_public_ip_on_launch = false
  tags = merge(merge(local.tags,
    {
      "Name"              = format("%s-subnet-%s-%s", var.name, local.database_subnets[count.index].type, local.database_subnets[count.index].az),
      "Subnet"            = local.database_subnets[count.index].name,
      "Cidr_block"        = local.database_subnets[count.index].cidr_block,
      "Availability_zone" = local.database_subnets[count.index].az,
      "Type"              = local.database_subnets[count.index].type
    }
  ), local.database_subnets[count.index].tags)
}

resource "aws_route_table_association" "database" {
  count = var.enabled && length(local.database_subnets) > 0 ? length(local.database_subnets) : 0

  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database[0].id
}

resource "aws_db_subnet_group" "database" {
  count = var.enabled && length(local.database_subnets) > 0 ? 1 : 0

  name        = lower(var.name)
  description = "Database subnet group for ${var.name}"
  subnet_ids  = aws_subnet.database.*.id

  tags = merge(
    local.tags,
    {
      "Name" = format("%s-db-subnet-group-database", var.name)
    }
  )
}

resource "aws_route_table" "redshift" {
  count = var.enabled && length(local.redshift_subnets) > 0 ? 1 : 0

  vpc_id = local.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.redshift_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "nat_gateway_id")
      ]
    ])

    content {
      cidr_block     = route.value.cidr_block
      nat_gateway_id = route.value.nat_gateway_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.redshift_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "instance_id")
      ]
    ])

    content {
      cidr_block  = route.value.cidr_block
      instance_id = route.value.instance_id
    }
  }

  dynamic "route" {
    for_each = flatten([
      for subnet in local.redshift_subnets : [
        for route in subnet["routes"] :
        route if contains(keys(route), "peering_id")
      ]
    ])

    content {
      cidr_block                = route.value.cidr_block
      vpc_peering_connection_id = route.value.peering_id
    }
  }

  tags = merge(
    local.tags,
    {
      "Name" = format("%s-route-table-redshift", var.name)
    }
  )
}

resource "aws_subnet" "redshift" {
  count = var.enabled && length(local.redshift_subnets) > 0 ? length(local.redshift_subnets) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = cidrsubnet(local.redshift_subnets[count.index].cidr_block, 0, 0)
  availability_zone       = local.redshift_subnets[count.index].az
  map_public_ip_on_launch = false
  tags = merge(merge(local.tags,
    {
      "Name"              = format("%s-subnet-%s-%s", var.name, local.redshift_subnets[count.index].type, local.redshift_subnets[count.index].az),
      "Subnet"            = local.redshift_subnets[count.index].name,
      "Cidr_block"        = local.redshift_subnets[count.index].cidr_block,
      "Availability_zone" = local.redshift_subnets[count.index].az,
      "Type"              = local.redshift_subnets[count.index].type
    }
  ), local.redshift_subnets[count.index].tags)
}

resource "aws_route_table_association" "redshift" {
  count = var.enabled && length(local.redshift_subnets) > 0 ? length(local.redshift_subnets) : 0

  subnet_id      = aws_subnet.redshift[count.index].id
  route_table_id = aws_route_table.redshift[0].id
}

resource "aws_redshift_subnet_group" "redshift" {
  count = var.enabled && length(local.redshift_subnets) > 0 ? 1 : 0

  name        = lower(var.name)
  description = "Redshift subnet group for ${var.name}"
  subnet_ids  = aws_subnet.redshift.*.id

  tags = merge(
    local.tags,
    {
      "Name" = format("%s-db-subnet-group-redshift", var.name)
    }
  )
}

resource "aws_vpc_peering_connection" "main" {
  count         = var.enabled && length(local.peers) > 0 ? length(local.peers) : 0
  vpc_id        = local.vpc_id
  peer_vpc_id   = local.peers[count.index].peer_vpc_id
  peer_owner_id = local.peers[count.index].peer_owner_id
  peer_region   = local.peers[count.index].peer_region
  auto_accept   = false

  tags = merge(local.tags,
    {
      "Name" = local.peers[count.index].name
    }
  )
}

