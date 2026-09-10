terraform {
  # The Network-as-Code module for IOS-XR needs a recent core; it uses
  # provider-defined functions (provider::utils::normalize_mask).
  required_version = ">= 1.9.0"
}
