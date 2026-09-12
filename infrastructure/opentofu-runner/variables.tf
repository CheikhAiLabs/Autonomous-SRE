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

variable "runner_type" {
  type    = string
  default = "DEV1-S"
}

variable "name" {
  type    = string
  default = "autonomous-sre-runner-01"
}
