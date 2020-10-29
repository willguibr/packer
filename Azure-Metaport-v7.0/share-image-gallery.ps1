$galleryName = 'MetaPortImageGallery'
$rgName = 'MetaPortImageGallery'

# Get the object ID for the group
$groupId = (Get-AzADGroup -DisplayName 'az-dg-image-gallery-readers').Id

# Grant reader access to the gallery
$params = @{
  ObjectId           = $groupId
  RoleDefinitionName = 'Reader'
  ResourceName       = $galleryName
  ResourceType       = Microsoft.Compute/galleries
  ResourceGroupName  = $rgName
}

New-AzRoleAssignment @params