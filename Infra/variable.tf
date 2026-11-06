variable "aws_region" {
  type        = string
  description = "The AWS Region where all resources will be deployed."
  default     = "us-east-1"
}

variable "app_name" {
  type        = string
  description = "The base naming prefix applied to all infrastructure components."
  default     = "todo-app"
}

variable "db_name" {
  type        = string
  description = "The initial database schema name created inside PostgreSQL."
  default     = "tododb"
}

variable "db_username" {
  type        = string
  description = "The master administrative username for the RDS database."
  default     = "cloudadmin"
}