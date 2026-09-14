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

variable "manager_cidr" {
  type = string
}

variable "runner_type" {
  type    = string
  default = "DEV1-M"
}

variable "runner_count" {
  type    = number
  default = 3
}

variable "name_prefix" {
  type    = string
  default = "autonomous-sre-build"
}
