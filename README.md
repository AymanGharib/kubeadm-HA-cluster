# kubeadm HA Cluster on AWS

Automates the provisioning and configuration of a **highly-available Kubernetes cluster** on AWS using **Terraform** (infrastructure) and **Ansible** (cluster bootstrap). The cluster runs Kubernetes 1.29 with the Calico CNI on Ubuntu 24.04 instances managed through an Auto Scaling Group.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [AWS Infrastructure](#aws-infrastructure)
- [Kubernetes Cluster Layout](#kubernetes-cluster-layout)
- [Network & Security Groups](#network--security-groups)
- [Setup Workflow](#setup-workflow)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [1. Provision Infrastructure with Terraform](#1-provision-infrastructure-with-terraform)
  - [2. Configure the Ansible Control Server](#2-configure-the-ansible-control-server)
  - [3. Bootstrap the Kubernetes Cluster](#3-bootstrap-the-kubernetes-cluster)
  - [4. Join Worker Nodes](#4-join-worker-nodes)
- [Repository Structure](#repository-structure)
- [Configuration Reference](#configuration-reference)

---

## Architecture Overview

```mermaid
graph TB
    subgraph AWS["AWS — eu-north-1"]
        subgraph VPC["VPC  10.123.0.0/16"]
            IGW[Internet Gateway]

            subgraph PubSubnet["Public Subnet  10.123.1.0/24"]
                ANSIBLE["🖥️ Ansible Server\nt3.micro · Ubuntu 24.04"]
                MASTER["⚙️ Kubernetes Master\nt3.micro · Ubuntu 24.04\nkubeadm · kubelet · kubectl"]
            end

            subgraph PrivSubnet["Private Subnet  10.123.2.0/24"]
                ASG["Auto Scaling Group\nmin 1 · desired 2 · max 5"]
                W1["🐳 Worker Node 1\nt3.micro · Ubuntu 24.04"]
                W2["🐳 Worker Node 2\nt3.micro · Ubuntu 24.04"]
                WN["🐳 Worker Node N"]
                ASG --> W1
                ASG --> W2
                ASG --> WN
            end

            IGW --> PubSubnet
            ANSIBLE -- "SSH + Ansible\nPlaybooks" --> MASTER
            ANSIBLE -- "SSH + Ansible\nPlaybooks" --> W1
            ANSIBLE -- "SSH + Ansible\nPlaybooks" --> W2
            MASTER -- "Kubernetes API\n:6443" --> W1
            MASTER -- "Kubernetes API\n:6443" --> W2
            MASTER -- "Kubernetes API\n:6443" --> WN
        end
    end

    USER["👤 User / Admin"] -- "kubectl / SSH" --> IGW
```

---

## AWS Infrastructure

Terraform provisions all infrastructure in **eu-north-1** across two availability zones.

```mermaid
graph LR
    subgraph Terraform Modules
        ROOT["root module\nterraform/main.tf"]
        NET["networking module\nterraform/networking/"]
        COMPUTE["compute module\nterraform/compute/"]
    end

    ROOT -->|cidr_block| NET
    ROOT -->|subnet IDs\nSecurity Group IDs| COMPUTE

    subgraph Networking Resources
        VPC["aws_vpc\n10.123.0.0/16"]
        PUB["aws_subnet\nPublic 10.123.1.0/24"]
        PRIV["aws_subnet\nPrivate 10.123.2.0/24"]
        IGW2["aws_internet_gateway"]
        PRT["Public Route Table\n0.0.0.0/0 → IGW"]
        PRIVRT["Private Route Table\n(no internet)"]
        SG_ANSIBLE["ansible_sg"]
        SG_MASTER["master_node_sg"]
        SG_WORKER["worker_node_sg"]
    end

    subgraph Compute Resources
        KP1["aws_key_pair\n(user SSH key)"]
        KP2["aws_key_pair\n(ansible SSH key)"]
        MASTER_EC2["aws_instance\nKubernetes-Master"]
        ANSIBLE_EC2["aws_instance\nAnsible-Server"]
        LT["aws_launch_template\nworker-node-*"]
        ASG2["aws_autoscaling_group\nworker_asg\ndesired=2 min=1 max=5"]
    end

    NET --> VPC
    NET --> PUB
    NET --> PRIV
    NET --> IGW2
    NET --> PRT
    NET --> PRIVRT
    NET --> SG_ANSIBLE
    NET --> SG_MASTER
    NET --> SG_WORKER

    COMPUTE --> KP1
    COMPUTE --> KP2
    COMPUTE --> MASTER_EC2
    COMPUTE --> ANSIBLE_EC2
    COMPUTE --> LT
    COMPUTE --> ASG2

    LT --> ASG2
```

---

## Kubernetes Cluster Layout

```mermaid
graph TB
    subgraph ControlPlane["Control Plane (Master Node)"]
        API["kube-apiserver\n:6443"]
        SCHED["kube-scheduler\n:10259"]
        CM["kube-controller-manager\n:10257"]
        ETCD["etcd\n:2379-2380"]
        KUBELET_M["kubelet\n:10250"]
        API --- ETCD
        API --- SCHED
        API --- CM
        API --- KUBELET_M
    end

    subgraph WorkerNodes["Worker Nodes (Auto Scaling Group)"]
        direction TB
        W_KUBELET["kubelet\n:10250"]
        W_PROXY["kube-proxy\n:10256"]
        W_CONT["containerd\nruntime"]
        W_PODS["Pods\n(NodePort :30000-32767)"]
        W_KUBELET --> W_CONT
        W_CONT --> W_PODS
    end

    subgraph CNI["Calico CNI v3.28.0"]
        TIGERA["Tigera Operator"]
        CALICO_PODS["Calico Pods\nPod CIDR: 192.168.0.0/16"]
        TIGERA --> CALICO_PODS
    end

    API -- "kubelet API" --> W_KUBELET
    API -- "kube-proxy" --> W_PROXY
    CNI -.->|overlay network| WorkerNodes
    CNI -.->|overlay network| ControlPlane
```

---

## Network & Security Groups

```mermaid
graph TD
    INTERNET["🌐 Internet"]

    subgraph PublicSubnet["Public Subnet"]
        ANSIBLE_NODE["Ansible Server"]
        MASTER_NODE["Master Node"]
    end

    subgraph PrivateSubnet["Private Subnet"]
        WORKER_NODES["Worker Nodes"]
    end

    INTERNET -- ":22 SSH" --> ANSIBLE_NODE
    INTERNET -- ":22 SSH\n:6443 API" --> MASTER_NODE

    MASTER_NODE -- ":10250 kubelet" --> WORKER_NODES
    ANSIBLE_NODE -- ":22 SSH" --> MASTER_NODE
    ANSIBLE_NODE -- ":22 SSH" --> WORKER_NODES

    MASTER_NODE -- ":2379-2380 etcd\n(VPC only)" --> MASTER_NODE
    WORKER_NODES -- ":30000-32767 NodePort\n(VPC only)" --> WORKER_NODES
```

| Security Group | Inbound Rules | Scope |
|---|---|---|
| **ansible_sg** | TCP 22 (SSH) | 0.0.0.0/0 |
| **master_node_sg** | TCP 22 (SSH) | 0.0.0.0/0 |
| | TCP 6443 (API server) | 0.0.0.0/0 |
| | TCP 2379–2380 (etcd) | VPC CIDR |
| | TCP 10250 (kubelet) | VPC CIDR |
| | TCP 10259 (scheduler) | self |
| | TCP 10257 (controller-manager) | self |
| **worker_node_sg** | TCP 22 (SSH) | 0.0.0.0/0 |
| | TCP 10250 (kubelet) | master_node_sg |
| | TCP 10256 (kube-proxy) | self |
| | TCP 30000–32767 (NodePort) | VPC CIDR |

---

## Setup Workflow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant TF as Terraform
    participant AWS as AWS
    participant Ansible as Ansible Server
    participant Master as Master Node
    participant Workers as Worker Nodes

    Dev->>TF: terraform init && terraform apply
    TF->>AWS: Create VPC, Subnets, IGW, Route Tables
    TF->>AWS: Create Security Groups
    TF->>AWS: Launch Master EC2 (user-data: install k8s components)
    TF->>AWS: Launch Ansible Server EC2 (user-data: install Ansible)
    TF->>AWS: Create Auto Scaling Group → Launch Worker EC2s (user-data: install k8s components)

    Dev->>Ansible: SSH in, update inventory file
    Dev->>Ansible: Run setup-cluster.yml
    Ansible->>Master: kubeadm init --pod-network-cidr=192.168.0.0/16
    Master-->>Ansible: join command

    Ansible->>Master: Install Calico CNI (Tigera operator + custom-resources)
    Ansible->>Master: Configure kubeconfig

    Dev->>Ansible: Run copy-config.yml
    Ansible->>Master: Replace localhost → master IP in kube-apiserver.yaml
    Ansible->>Master: Restart kubelet

    Dev->>Ansible: Run copy-token.yml
    Ansible->>Master: kubeadm token create --print-join-command
    Master-->>Ansible: join token saved to ./kubeadm_join_token.txt

    Dev->>Ansible: Run join-master.yml
    Ansible->>Workers: kubeadm join <master-ip>:6443 --token ...
    Workers-->>Master: Nodes register with control plane

    Dev->>Master: kubectl get nodes (cluster ready ✅)
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | ≥ 1.0 | Infrastructure provisioning |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | ≥ 2.x | AWS credentials & API access |
| SSH key pair | — | Access to EC2 instances |

**AWS credentials** must be configured (via `aws configure` or environment variables) with permissions to manage EC2, VPC, IAM key pairs, and Auto Scaling resources.

---

## Quick Start

### 1. Provision Infrastructure with Terraform

```bash
# Generate two SSH key pairs: one for your local access, one for the Ansible server
ssh-keygen -t ed25519 -f terraform/id_ed25519 -N ""
ssh-keygen -t ed25519 -f terraform/ansiblekey -N ""

cd terraform
terraform init
terraform apply
```

Terraform outputs the public IPs of the master node, Ansible server, and worker nodes.

### 2. Configure the Ansible Control Server

SSH into the Ansible server and activate the virtual environment that was set up by `ansible-setup.tpl`:

```bash
ssh -i terraform/id_ed25519 ubuntu@<ANSIBLE_SERVER_IP>

cd ansible
source myansible/bin/activate
ansible --version   # verify Ansible is installed
```

Copy the Ansible playbooks and the private key (for reaching master & workers) onto the Ansible server:

```bash
# From your local machine
scp -i terraform/id_ed25519 -r ansible-playbooks ubuntu@<ANSIBLE_SERVER_IP>:~/
scp -i terraform/id_ed25519 terraform/ansiblekey ubuntu@<ANSIBLE_SERVER_IP>:~/.ssh/id_ed25519
```

Update `ansible-playbooks/inventory` with the actual public IPs from Terraform output:

```ini
[master]
ubuntu@<MASTER_PUBLIC_IP>

[worker]
ubuntu@<WORKER_1_PUBLIC_IP>
ubuntu@<WORKER_2_PUBLIC_IP>
```

### 3. Bootstrap the Kubernetes Cluster

Run the playbooks from the Ansible server in order:

```bash
cd ~/ansible-playbooks

# 1. Initialize the control plane and install Calico CNI
ansible-playbook -i inventory setup-cluster.yml

# 2. Fix the kube-apiserver bind address and set up kubeconfig
ansible-playbook -i inventory copy-config.yml
```

### 4. Join Worker Nodes

```bash
# 3. Generate a join token and save it locally
ansible-playbook -i inventory copy-token.yml

# 4. Join all worker nodes to the cluster
ansible-playbook -i inventory join-master.yml
```

Verify the cluster from the master node:

```bash
ssh -i terraform/ansiblekey ubuntu@<MASTER_PUBLIC_IP>
kubectl get nodes
```

Expected output:

```
NAME       STATUS   ROLES           AGE   VERSION
master     Ready    control-plane   5m    v1.29.6
worker-1   Ready    <none>          3m    v1.29.6
worker-2   Ready    <none>          3m    v1.29.6
```

---

## Repository Structure

```
kubeadm-HA-cluster/
├── terraform/                     # Infrastructure as Code (AWS)
│   ├── providers.tf               # AWS provider (eu-north-1)
│   ├── main.tf                    # Root module — wires networking + compute
│   ├── variables.tf               # Root variables (VPC CIDR)
│   ├── master-userdata.tpl        # Cloud-init: install k8s components on master
│   ├── worker-userdata.tpl        # Cloud-init: install k8s components on workers
│   ├── ansible-setup.tpl          # Cloud-init: install Ansible on control server
│   ├── networking/
│   │   ├── main.tf                # VPC, subnets, IGW, route tables, security groups
│   │   ├── variables.tf
│   │   └── output.tf
│   └── compute/
│       ├── main.tf                # EC2 instances, launch template, ASG, key pairs
│       ├── variables.tf
│       └── output.tf
└── ansible-playbooks/             # Cluster configuration automation
    ├── inventory                  # Host groups: [master] and [worker]
    ├── setup-cluster.yml          # kubeadm init + Calico CNI installation
    ├── copy-config.yml            # Fix API server address + kubeconfig setup
    ├── copy-token.yml             # Generate & fetch worker join token
    └── join-master.yml            # Join worker nodes to the cluster
```

---

## Configuration Reference

| Parameter | Default | Description |
|---|---|---|
| `cidr_block` | `10.123.0.0/16` | VPC CIDR block |
| `instance_type` | `t3.micro` | EC2 instance type for all nodes |
| `vol_size` | `8` GB | Root EBS volume size |
| `worker_count` | `2` | Desired number of worker nodes |
| `key_name` | `mylocal-key` | Name of the user SSH key pair in AWS |
| `ansible_key_name` | `ansible_key` | Name of the Ansible SSH key pair in AWS |
| Kubernetes version | `1.29.6-1.1` | Pinned via `apt-mark hold` |
| Containerd version | `1.7.14` | Container runtime |
| runc version | `1.1.12` | OCI runtime |
| CNI plugins version | `1.5.0` | CNI binary plugins |
| Calico version | `v3.28.0` | Pod network CNI |
| Pod network CIDR | `192.168.0.0/16` | Calico pod IP range |
| AWS region | `eu-north-1` | Stockholm |
