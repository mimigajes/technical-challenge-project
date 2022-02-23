terraform {
  backend "gcs" {
    bucket = "tf-state-host-project"
    prefix = "tf-state"
 }
}