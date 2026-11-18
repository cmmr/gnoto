# gnoto

gnoto runs CMMR's microbiome pipelines, ampliseq, taxprofiler and biobakery, as one
installable tool in which every run is exactly reproducible. Each job names a commit of
gnoto, and that commit pins every image, database and parameter the run uses, so the same
job gives the same results wherever and whenever it runs.

The [README](https://github.com/cmmr/gnoto#readme) says what gnoto does and how to install
it. These pages guide its setup.

- [Setting up Wrike](wrike.md): a space, workflow, folder and request form for gnoto's
  jobs, so each has a Wrike task and a request form can start them.
