####################################################################################
# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
####################################################################################

####################################################################################
#
####################################################################################


terraform {
  required_providers {
    google = {
      source  = "hashicorp/google-beta"
      version = "4.15.0"
    }
  }
}


####################################################################################
# Variables
####################################################################################
variable "gcp_account_name" {}
variable "project_id" {}
variable "region" {}
variable "zone" {}
variable "storage_bucket" {}
variable "spanner_config" {}
variable "random_extension" {}
variable "project_number" {}
variable "deployment_service_account_name" {}


####################################################################################
# Bucket for all data (BigQuery, Spark, etc...)
# This is your "Data Lake" bucket
# If you are using Dataplex you should create a bucket per data lake zone (bronze, silver, gold, etc.)
####################################################################################
resource "google_storage_bucket" "main_bucket" {
  project                     = var.project_id
  name                        = var.storage_bucket
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}


####################################################################################
# Default Network
# The project was not created with the default network.  
# This creates just the network/subnets we need.
####################################################################################
resource "google_compute_network" "default_network" {
  project                 = var.project_id
  name                    = "vpc-main"
  description             = "Default network"
  auto_create_subnetworks = false
  mtu                     = 1460
}

####################################################################################
# Networking 
####################################################################################
# Subnet for pilot project 
resource "google_compute_subnetwork" "subnet1" {
  project       = var.project_id
  name          = "subnet1"
  ip_cidr_range = "10.3.0.0/16"
  region        = var.region
  network       = google_compute_network.default_network.id

  depends_on = [
    google_compute_network.default_network,
  ]
}

# Firewall rule for dataproc cluster
resource "google_compute_firewall" "subnet1_firewall_rule" {
  project  = var.project_id
  name     = "subnet1-firewall"
  network  = google_compute_network.default_network.id

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }
  source_ranges = ["10.3.0.0/16"]

  depends_on = [
    google_compute_subnetwork.subnet1
  ]
}

# Temp work bucket for datalake
# If you do not have a perminate temp bucket random ones will be created (which is messy since you do not know what they are being used for)
resource "google_storage_bucket" "datalake_bucket" {
  project                     = var.project_id
  name                        = "datalake-${var.storage_bucket}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}


# Service account for  cluster
resource "google_service_account" "bqpilot_service_account" {
  project      = var.project_id
  account_id   = "bqpilot-service-account"
  display_name = "Service Account for BQ Environment"
}


####################################################################################
# BigQuery Datasets
####################################################################################
resource "google_bigquery_dataset" "bqpilot_dataset" {
  project       = var.project_id
  dataset_id    = "bqpilot_dataset"
  friendly_name = "bqpilot_dataset"
  description   = "This contains the Bigquery pilot data"
  location      = var.region
}

####################################################################################
# Data Catalog Taxonomy
####################################################################################
resource "google_data_catalog_taxonomy" "business_critical_taxonomy" {
  project  = var.project_id
  region   = var.region
  # Must be unique accross your Org
  display_name           = "Business-Critical-${var.random_extension}"
  description            = "A collection of policy tags"
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
}

resource "google_data_catalog_policy_tag" "low_security_policy_tag" {
  taxonomy     = google_data_catalog_taxonomy.business_critical_taxonomy.id
  display_name = "Low security"
  description  = "A policy tag normally associated with low security items"

  depends_on = [
    google_data_catalog_taxonomy.business_critical_taxonomy,
  ]
}

resource "google_data_catalog_policy_tag" "high_security_policy_tag" {
  taxonomy     = google_data_catalog_taxonomy.business_critical_taxonomy.id
  display_name = "High security"
  description  = "A policy tag normally associated with high security items"

  depends_on = [
    google_data_catalog_taxonomy.business_critical_taxonomy,
  ]
}

resource "google_data_catalog_policy_tag_iam_member" "member" {
  policy_tag = google_data_catalog_policy_tag.low_security_policy_tag.name
  role       = "roles/datacatalog.categoryFineGrainedReader"
  member     = "user:${var.gcp_account_name}"
  depends_on = [
    google_data_catalog_policy_tag.low_security_policy_tag,
  ]
}


####################################################################################
# BigQuery Table with Column Level Security
####################################################################################
resource "google_bigquery_table" "default" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.bqpilot_dataset.dataset_id
  table_id   = "taxi_trips_with_col_sec"

  clustering = ["Pickup_DateTime"]

  schema = <<EOF
[
  {
    "name": "Vendor_Id",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "Pickup_DateTime",
    "type": "TIMESTAMP",
    "mode": "NULLABLE"
  },
  {
    "name": "Dropoff_DateTime",
    "type": "TIMESTAMP",
    "mode": "NULLABLE"
  },
  {
    "name": "Passenger_Count",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "Trip_Distance",
    "type": "FLOAT64",
    "mode": "NULLABLE"
  },
  {
    "name": "Rate_Code_Id",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "Store_And_Forward",
    "type": "STRING",
    "mode": "NULLABLE"
  },
  {
    "name": "PULocationID",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "DOLocationID",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "Payment_Type_Id",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "Fare_Amount",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.low_security_policy_tag.id}"]
      }
  },
  {
    "name": "Surcharge",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.low_security_policy_tag.id}"]
      }
  },
  {
    "name": "MTA_Tax",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.low_security_policy_tag.id}"]
      }
  },
  {
    "name": "Tip_Amount",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.high_security_policy_tag.id}"]
      }
  },
  {
    "name": "Tolls_Amount",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.low_security_policy_tag.id}"]
      }
  },
  {
    "name": "Improvement_Surcharge",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.low_security_policy_tag.id}"]
      }
  },
  {
    "name": "Total_Amount",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.high_security_policy_tag.id}"]
      }
  },
  {
    "name": "Congestion_Surcharge",
    "type": "FLOAT64",
    "mode": "NULLABLE",
    "policyTags": {
        "names": ["${google_data_catalog_policy_tag.low_security_policy_tag.id}"]
      }
  }     
]
EOF
  depends_on = [
    google_data_catalog_taxonomy.business_critical_taxonomy,
    google_data_catalog_policy_tag.low_security_policy_tag,
    google_data_catalog_policy_tag.high_security_policy_tag,
  ]
}


####################################################################################
# Outputs
####################################################################################

