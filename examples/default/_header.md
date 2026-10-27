# Default example

This example shows how to deploy the module in its simplest configuration.

It replaces the previous `default-azurerm-v3` and `default-azurerm-v4` examples. Those two existed only to prove that the module worked against both major versions of the `hashicorp/azurerm` provider; this module no longer uses that provider, so the distinction no longer exists and a single example covers it.

The resource group is created with `azapi_resource`, and the module is called with the required `parent_id` input.
