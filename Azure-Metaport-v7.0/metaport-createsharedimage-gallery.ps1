# create shared image gallery

$Name = 'MetaPortImageGallery'
$location = 'canadacentral'
$tags = @{'Environment' = 'Dev'; 'Description' = 'Metaport Resources for packer image builds' }

$resourceGroup = New-AzResourceGroup -Name $Name -Location $location -Tag $tags -Verbose
$gallery = New-AzGallery -GalleryName $Name -ResourceGroupName $Name -Location $location -Description ' MetaPort Shared Image Gallery' -Tag $tags -Verbose