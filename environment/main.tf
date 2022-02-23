/******************************************
  Provider configuration
 *****************************************/
provider "google" {
  region = var.region
  project = var.host_project_id
}

locals {
  net_data_users = compact(concat(
    var.service_project_owners,
    ["serviceAccount:${var.service_project_number}@cloudservices.gserviceaccount.com"]
  ))
}



module "net-vpc-shared" {
  source          = "../modules/vpc-module"
  project_id      = var.host_project_id
  network_name    = var.network_name
  shared_vpc_host = true
}



module "subnets" {
  source          = "terraform-google-modules/network/google"
  project_id      = var.host_project_id
  network_name    = module.net-vpc-shared.network_name

  subnets = var.subnets
}

resource "google_compute_subnetwork" "sub3" {
  name          = "sub3"
  ip_cidr_range = "10.0.1.0/24"
  region        = "us-east2"
  network       = module.net-vpc-shared.network_name
}

module "net-svpc-access" {
  source              = "../modules/fabric-net-svpc-access"
  host_project_id     = var.host_project_id
  service_project_num = var.service_project_number
  service_project_ids = [var.service_project_id]
  host_subnets        = var.host-subnet
  host_subnet_regions = var.host-subnet-region
}


module "firewall_rules" {
  source       = "../modules/firewall-module"
  project_id   = var.host_project_id
  network_name = module.net-vpc-shared.network_name

  rules = var.rules
}

resource "google_compute_instance" "public-vm" {
  project      = var.service_project_id
  zone         = var.pub-vm-zone
  name         = var.pub-vm-name
  machine_type = var.machine-type
  boot_disk {
    initialize_params {
      image = "projects/rhel-cloud/global/images/rhel-8-v20220126"
      size = "20"
    }
  }
  network_interface {
    network    = module.net-vpc-shared.network_name
    subnetwork = module.subnets.subnets[0]

    access_config {
        // Ephemeral public IP
  }
  }
  

}


resource "google_compute_instance" "private-vm" {
  project      = var.service_project_id
  zone         = var.priv-vm-zone
  name         = var.priv-vm-name
  machine_type = var.machine-type
  tags = var.tags
  metadata_startup_script = "${file("${path.module}/script/apache.sh")}"
  boot_disk {
    initialize_params {
      image = "projects/rhel-cloud/global/images/rhel-8-v20220126"
      size = "20"
    }
  }
  network_interface {
    network    = module.net-vpc-shared.network_name
    subnetwork = google_compute_subnetwork.sub3.id
  }
}



# [START cloudnat_router_nat_gce]
resource "google_compute_router" "router" {
  project = var.service_project_id
  name    = "nat-router"
  network = module.net-vpc-shared.network_name
  region  = "us-east2"
}


# [START cloudnat_nat_gce]
module "cloud-nat" {
  source                             = "../modules/cloud-nat-module"
  project_id                         = var.host_project_id
  region                             = "us-east2"
  router                             = google_compute_router.router.name
  name                               = "nat-config"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_network_endpoint_group" "neg" {
  name         = "my-lb-neg"
  network      =  "projects/${var.host_project_id}/global/networks/${module.net-vpc-shared.network_name}"
  project      =   var.service_project_id
  subnetwork   = "sub3" 
  default_port = "80"
  zone         = "us-east2-a" 
}
resource "google_compute_network_endpoint" "default-endpoint" { 
  network_endpoint_group = google_compute_network_endpoint_group.neg.name
  port       = google_compute_network_endpoint_group.neg.default_port
  instance   = google_compute_instance.private-vm.name
  ip_address = google_compute_instance.private-vm.network_interface[0].network_ip
  zone         = "us-east2-a" 
  project      =   var.service_project_id
}




# [START cloudloadbalancing_ext_http_gce_shared_vpc]
module "gce-lb-http" {
  source            = "GoogleCloudPlatform/lb-http/google"
  version           = "~> 5.1"
  name              = "group-http-lb"
  project           = var.service_project_id
  target_tags       = ["gce-lb"]
  firewall_projects = [var.host_project_id]
  firewall_networks = [module.net-vpc-shared.network_name]

  backends = {
    default = {
      description                     = null
      protocol                        = "HTTP"
      port                            = 80
      port_name                       = "http"
      timeout_sec                     = 10
      connection_draining_timeout_sec = null
      enable_cdn                      = false
      security_policy                 = null
      session_affinity                = null
      affinity_cookie_ttl_sec         = null
      custom_request_headers          = null
      custom_response_headers         = null

      health_check = {
        check_interval_sec  = null
        timeout_sec         = null
        healthy_threshold   = null
        unhealthy_threshold = null
        request_path        = "/"
        port                = 80
        host                = null
        logging             = null
      }

      log_config = {
        enable      = true
        sample_rate = 1.0
      }

      groups = [
        {
          group                        = null
          balancing_mode               = null
          capacity_scaler              = null
          description                  = null
          max_connections              = null
          max_connections_per_instance = null
          max_connections_per_endpoint = null
          max_rate                     = null
          max_rate_per_instance        = null
          max_rate_per_endpoint        = null
          max_utilization              = null
        }
      ]

      iap_config = {
        enable               = false
        oauth2_client_id     = ""
        oauth2_client_secret = ""
      }
    }
  }
}