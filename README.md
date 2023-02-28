# Introduction 
A PowerShell script deploy Linux VMs with [Cloud-init](https://cloudinit.readthedocs.io/en/latest/index.html) to efficiently provision a Linux VM on Hyper-V.

Cloud-init is the industry standard multi-distribution method for cross-platform cloud instance initialization. For the local environment, Cloud-init can also work with the NoCloud data source:

> The data source NoCloud allows the user to provide user-data and meta-data to the instance without running a network service (or even without having a network at all).

See the [link](https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html) for details.

# Getting Started

## Run the script to deploy a Linux VM with cloud-init configs
> **Note**: Currently only Ubuntu 20.04 cloud image is tested

1. Prepare your cloud-init config files: `meta-data` and `user-data`. If you are not sure how to do it, use the sample configs in [sample-config](./sample-config/).

2. Find the URI that points to your cloud image. We are using Ubuntu 20.04 (focal) daily image as an example: https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img

3. Run the script `new-cloudinit-vm.ps1` with these mandatory arguments:
    ```
    .\new-cloudinit-vm.ps1 `
        -VMName ubuntu-with-cloudinit `
        -CloudImageUri https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img `
        -MetaDataPath sample-config\meta-data `
        -UserDataPath sample-config\user-data
    ```
    If you want to provide cloud init configs with variables:
    ```
    .\new-cloudinit-vm.ps1 `
        -VMName ubuntu-with-cloudinit `
        -CloudImageUri https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img `
        -MetaData $metadata `
        -UserData $userdata
    ```
    Check out the [script](./new-cloudinit-vm.ps1) itself for optional arguments, for example the virtual switch to connect `-VMSwitchName`.

4. Based on the sample cloud init config, the VM will be started automatically, and will be shutdown after configuration is done.

5. Start the VM again and log into the VM with username `ubuntu` and `password`.

# Known issues

- To inject the cloud-init data into the VM, a virtual disk (VHDX) will be created and mounted to the VM. You will have to manually unmount and remove this virtual disk.
