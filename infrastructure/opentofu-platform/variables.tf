variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "fr-par"
}

variable "zone" {
  type    = string
  default = "fr-par-1"
}

variable "operator_cidr" {
  type = string
}

variable "runner_cidr" {
  type = string
}

variable "control_plane_type" {
  type    = string
  default = "DEV1-L"
}

variable "worker_type" {
  type    = string
  default = "DEV1-XL"
}

variable "worker_count" {
  type    = number
  default = 2

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 5
    error_message = "worker_count must be between 1 and 5."
  }
}

variable "private_network_cidr" {
  type    = string
  default = "172.20.0.0/24"
}
