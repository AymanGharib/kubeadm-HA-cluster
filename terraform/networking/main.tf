// VPC
resource "aws_vpc" "kubeadm" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  lifecycle {
    create_before_destroy = true
  }
}

// Get AZs
data "aws_availability_zones" "available" {}

resource "random_shuffle" "list_azs" {
  input        = data.aws_availability_zones.available.names
  result_count = 2 # We only need 2 AZs, one for each subnet
}

// Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.kubeadm.id
  cidr_block              = var.public_subnet_cidr[0]
  map_public_ip_on_launch = true
  availability_zone       = random_shuffle.list_azs.result[0]

  tags = {
    Name = "Public Subnet"
  }
}

// Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.kubeadm.id
  cidr_block              = var.private_subnet_cidr[0]
  map_public_ip_on_launch = false
  availability_zone       = random_shuffle.list_azs.result[1]

  tags = {
    Name = "Private Subnet"
  }
}

// Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.kubeadm.id

  tags = {
    Name = "Kubeadm IGW"
  }
}

// Public Route Table (for internet access)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.kubeadm.id
}

// Route for Public Subnet -> Internet
resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

// Associate Public Subnet with Public Route Table
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

// Private Route Table (No Internet)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.kubeadm.id
}

// Associate Private Subnet with Private Route Table
resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}


// set up security groups


resource "aws_security_group" "ansible_sg" {
    name        = "anisble-sg"

    vpc_id      = aws_vpc.kubeadm.id
    ingress  {

    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]

  }




}







resource "aws_security_group" "master_node_sg" {
  name        = "master-node-sg"
  description = "Security group for Kubernetes master node"
  vpc_id      = aws_vpc.kubeadm.id

  // Kubernetes API server (Accessible from worker nodes & external clients)
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Change to VPC CIDR for internal access only
  }

  ingress  {

    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]

  }


  // etcd server client API (Only accessible from control plane components)
  ingress {
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.kubeadm.cidr_block] # Restrict to VPC
  }

  // Kubelet API (Workers need to communicate with master)
  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.kubeadm.cidr_block] # Restrict to VPC
  }

  // kube-scheduler (Self-restricted)
  ingress {
    from_port = 10259
    to_port   = 10259
    protocol  = "tcp"
    self      = true # Only master node can access this
  }

  // kube-controller-manager (Self-restricted)
  ingress {
    from_port = 10257
    to_port   = 10257
    protocol  = "tcp"
    self      = true # Only master node can access this
  }

  // Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Master Node Security Group"
  }
}


resource "aws_security_group" "worker_node_sg" {
  name        = "worker-node-sg"
  description = "Security group for Kubernetes worker nodes"
  vpc_id      = aws_vpc.kubeadm.id

  // Kubelet API (Allow control plane to communicate)
  ingress {
    from_port       = 10250
    to_port         = 10250
    protocol        = "tcp"
    security_groups = [aws_security_group.master_node_sg.id] # Restrict to Master SG
  }

  // kube-proxy (Internal use for networking, Load Balancers need access)
  ingress {
    from_port = 10256
    to_port   = 10256
    protocol  = "tcp"
    self      = true # Allow worker node itself & Load Balancers
  }

  // NodePort Services (Allow external access to services)
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.kubeadm.cidr_block]
  }

  // Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Worker Node Security Group"
  }
}
