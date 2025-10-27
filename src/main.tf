terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.92"
    }
  }
}

provider "yandex" {
  zone = "ru-central1-a"
}

resource "yandex_vpc_network" "redis-network" {
  name = "redis-cluster-network"
}

resource "yandex_vpc_subnet" "redis-subnets" {
  count = 3
  name           = "redis-subnet-${count.index}"
  zone           = element(["ru-central1-a", "ru-central1-b", "ru-central1-c"], count.index)
  network_id     = yandex_vpc_network.redis-network.id
  v4_cidr_blocks = [element(["192.168.10.0/24", "192.168.20.0/24", "192.168.30.0/24"], count.index)]
}

resource "yandex_compute_instance" "redis-node" {
  count = 3
  
  name        = "redis-node-${count.index + 1}"
  platform_id = "standard-v3"
  zone        = element(["ru-central1-a", "ru-central1-b", "ru-central1-c"], count.index)

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = "fd827b91d99psvq5fjit" # Ubuntu 22.04
      size     = 20
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.redis-subnets[count.index].id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_rsa")
    host        = self.network_interface[0].nat_ip_address
  }

  # Установка Redis
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y redis-server",
      "sudo systemctl stop redis-server"
    ]
  }

  # Настройка конфигурации Redis
  provisioner "file" {
    content = templatefile("${path.module}/redis-cluster.conf.tpl", {
      node_ip = self.network_interface[0].ip_address
    })
    destination = "/tmp/redis-cluster.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/redis-cluster.conf /etc/redis/redis-cluster.conf",
      "sudo chown redis:redis /etc/redis/redis-cluster.conf"
    ]
  }
}

resource "yandex_vpc_security_group" "redis-sg" {
  name       = "redis-cluster-sg"
  network_id = yandex_vpc_network.redis-network.id

  ingress {
    protocol       = "TCP"
    port           = 6379
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    port           = 16379
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Output для удобства
output "redis_nodes_ips" {
  value = {
    for idx, node in yandex_compute_instance.redis-node :
    "node-${idx + 1}" => {
      external_ip = node.network_interface[0].nat_ip_address
      internal_ip = node.network_interface[0].ip_address
    }
  }
}

output "cluster_creation_command" {
  value = <<EOT
  
  Для создания кластера выполните на любой ноде:
  
  redis-cli --cluster create \\
    ${yandex_compute_instance.redis-node[0].network_interface[0].ip_address}:6379 \\
    ${yandex_compute_instance.redis-node[1].network_interface[0].ip_address}:6379 \\
    ${yandex_compute_instance.redis-node[2].network_interface[0].ip_address}:6379 \\
    --cluster-replicas 1
  
  EOT
}