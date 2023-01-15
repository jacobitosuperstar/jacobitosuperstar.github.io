---
title: transferencia de archivos entre nubes
date: 2022-08-26T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["python"]
categories: ["programming"]
---

Sometimes is a requeriment to transfer files from one cloud service to another.
At least that was the challenge that I encountered while developing a file
classification web service. Mid development cycle they changed their cloud
provider because of some juicy Azure discounts and the all so great office 365
integration.

The compromise reached to be able to continue at the same development speed was
to continue to work on AWS in the web service, but the files finished the
process, must be transfered to Azure.

With all the restrictions regarding failure uppon transfer and other things,
there are two that are the most relevant to do a general solution, which are:

* The server can't download the files from S3, because some of them are in the
    houndreds of gigabytes realm and the webserver that we are currently using,
    cannot scale up the hard drive to that capacity without leaving us broke.

* We should be able to send several files at the same time.

Given those restrictions what I thought about doing is to generate a public url
of the requested file, then download it and stream it to the other cloud.

for requeriments to implement this code this are the packages and the Python
version which I was working with at the time of writting this article. Also is
spected a basic knowlegde of AWS S3 and Azure APIs.

```toml
[packages]
  boto3 = "==1.21"
  azure-storage-blob = "==12.10"
  requests = "==2.27"

[requires]
  python_version = "3.9"
```

For azure, there is a CLI tool called [azcopy][1], from microsoft that allows
for multithreaded parallel download and upload of files, and given the
restrictions of your own problem is worth checking out. In our case, the tool
still needs to have the file in the hardrive, which as we said before is
something we cannot have.

for a start we need the azure blob client for the container and the destination
file that we are going to create.

```python
# Azure Blob Storage packages
from azure.storage.blob import (
    BlobServiceClient,
    BlobClient,
)

def get_azure_blob_client(
    *,
    azure_storage_container_name: str,
    azure_storage_blob_name: str,
    azure_storage_account_name: str = None,
    azure_storage_access_key: str = None,
    azure_storage_connection_string: str = None,
) -> BlobClient:
    # accesing AzureStorage
    if azure_storage_connection_string is not None:
        # log on with the connection string
        try:
            blob_client = BlobClient.from_connection_string(
                conn_str=azure_storage_connection_string,
                container_name=azure_storage_container_name,
                blob_name=azure_storage_blob_name,
            )
        except Exception as e:
            print(e)
            return
    else:
        # log on with the account name and the access key
        try:
            account_url = (
                'https://'
                f'{azure_storage_account_name}'
                'blob.core.windows.net/'
            )
            blob_client = BlobServiceClient(
                account_url=account_url,
                credential=azure_storage_access_key,
            ).get_blob_client(
                container=azure_storage_container_name,
                blob=azure_storage_blob_name,
            )
        except Exception as e:
            print(e)
            return

    return blob_client
```

For the azure authentication is needed one of these, the
`azure_storage_account_name` and the `azure_storage_access_key` or the
`azure_storage_connection_string`, to be able to connect to the azure storage
service.

The `*` means, in case you don't know, that only named parameters are allowed
if you want to use positional arguments you can delete it, but I personally
prefer explicit code.

The `azure_storage_account_name`, is the Windows Azure Storage
Account name, which in many cases is also the first part of the url for
instance: `http://azure_storage_account_name.blob.core.windows.net/` would
mean.

The `azure_storage_access_key`, is the key that gives us access to the account.

The `azure_storage_connection_string`, If specified, this will override
all other parameters.

The `azure_storage_blob_name` is the destination name, if it happends to be
`None`, it will be equal to the `aws_object_key` and we will specify that later
on the code.

now for the AWS S3 client we have,

```Python
import boto3

def get_s3_client(
    *,
    aws_access_key_id: str,
    aws_secret_access_key: str,
    aws_storage_bucket_name: str,
):
    # accessing the AWS bucket
    try:
        aws_session = boto3.session(
            aws_access_key_id=aws_access_key_id,
            aws_secret_access_key=aws_secret_access_key
        )
    except Exception as e:
        # we all know that the print statement is the only way to debug
        print(e)
        return

    s3_client = aws_session.client('s3')
    return s3_client
```

Where,
the `aws_access_key_id` is the AWS access key.
the `aws_secret_access_key` is the AWS S3 secret access key
the `aws_storage_bucket_name` is the AWS S3 Bucket name.

We will need and ID generator, in case we don't want to replace the files that
are already on the Blob Container, which will be as follows,

```Python
import random
import string


def id_generator(
    size: int = 6,
    chars: str = (
        string.ascii_uppercase + string.digits + string.ascii_lowercase
    )
) -> str:
    """Random ID generator. By default the IDs are 6 characters long.
    """
    return ''.join(random.choice(chars) for _ in range(size))
```

Now that we have both clients and the ID generator to differentiate files, is
time to generate the code that will manage the file transfer.

Like I said before the idea is to request the file throught a stream of data,
and then upload it chunk by chunk into the cloud. In that way the only part of
the file that we will have in our hardrive is the current chuck of file but
nothing more.

To do it, we have to generate a public URL in case the file is private,

`aws_url_expiration_time` is the expiration time of the presigned url of the S3
object. The documentation states that the maximun ammount that a presigned url
is able to stay up is 7 days, which are 604800 seconds.

Is important to note that if the file can't be downloaded and transfered in the
7 days, the file will remain as a partial transfer, and you won't have the full
information.

```Python
object_url = s3_client.generate_presigned_url(
    "get_object",
    params={
        "Bucket": aws_storage_bucket_name,
        "key": aws_object_key,
    },
    ExpiresIn=aws_url_expiration_time
)
```

Then we have to create the stream from the file that we are requesting, and
using the requests package is really simple, because it is only an option. So
we have,

```Python
object_stream = requests.get(object_url, stream=True)
```

As something important at least for us in the project, was the hability to
check if the file already exists in the Azure container, so there is a function
that checks the existence of the files,

```Python
blob_client.exists()
```

That returns a Boolean value, and given the desires of the user, we can delete
and reaupload the file, or use the ID module to generate a differente name, and
loop on it until we find a non repeated name that we can use to upload.

And if the original file needs to be deleted, in our case it was needed the
option because some files had the requirement to stay on both folders until the
client finds it convinient, we can just delete the file from S3,

```Python
s3_client.delete_object(
    Bucket=aws_storage_bucket_name,
    Key=aws_object_key,
)
```

Putting it all together, this is the final function that was created to solve
the problem in hand.

You can use the same code for the AWS S3 Client and the Azure Blob Client, same
as the ID generator, which will be referenced here, as this section is only
about the file transfer, given the storage connections and name conditions are
already set.

```Python
# python packages
import os
# Third party packages
import requests
# AWS S3 packages
from botocore.exceptions import ClientError
# Azure Blob Storage packages
# Local Imports
from .utils import id_generator
from .storage_connections import (
    get_s3_client,
    get_azure_blob_client,
    azure_url_generator,
)

def s3_to_azure(
    *,
    aws_object_key: str,
    azure_storage_container_name: str,
    aws_access_key_id: str = os.environ.get("AWS_ACCESS_KEY_ID"),
    aws_secret_access_key: str = os.environ.get("AWS_SECRET_ACCESS_KEY"),
    aws_storage_bucket_name: str = os.environ.get("AWS_STORAGE_BUCKET_NAME"),
    aws_public_object: bool = False,
    aws_url_expiration_time: int = 3600,
    aws_delete_after_transfer: bool = False,
    azure_storage_account_name: str = os.environ.get("AZURE_STORAGE_ACCOUNT_NAME"),
    azure_storage_access_key: str = os.environ.get("AZURE_STORAGE_ACCESS_KEY"),
    azure_storage_connection_string: str = os.environ.get("AZURE_STORAGE_CONNECTION_STRING"),
    azure_storage_blob_name: str = None,
    azure_storage_blob_overwrite: bool = False,
) -> dict:
    """
    This function gets an existing file from S3 and transfer it to Azure
    Storage in a data stream, so no excesive memory is used beign local storage
    or in memory storage, just bandwith.

    :type aws_access_key_id: str
    :param aws_access_key_id => AWS access key, it tries to take the one from
                                the enviroment variables if nothing is put.
    :type aws_secret_access_key: str
    :param aws_secret_access_key => AWS S3 secret access key, it tries to take
                                    the one from the enviroment variables if
                                    nothing is put.
    :type aws_storage_bucket_name: str
    :param aws_storage_bucket_name => AWS S3 Bucket name.
    :type aws_object_key: str
    :param aws_object_key => the key of the object that we are going to
                             transfer.
    :type aws_public_object: bool
    :param aws_public_object => if the object if public or not. It creates a
                                minimal URL in case it is.
    :type aws_url_expiration_time: int
    :param aws_url_expiration_time => URL expiration time in seconds
    :type aws_delete_after_transfer: bool
    :param aws_delete_after_transfer => Boolean to check if the original file
                                        will be deleted or not. By default is
                                        False.

    For the azure authentication is needed, the azure_storage_account_name
    and the azure_storage_access_key or the azure_storage_connection_string,
    to be able to connect to the azure storage service.

    :type azure_storage_account_name: str
    :param azure_storage_account_name => This is the Windows Azure Storage
                                         Account name
    :type azure_storage_access_key: str
    :param azure_storage_access_key => Key that gives us access to the account.
    :type azure_storage_connection_string: str
    :param azure_storage_connection_string => If specified, this will override
                                              all other parameters.
    :type azure_storage_blob_name: str
    :param azure_storage_blob_name => The destination name, if it happends to
                                      be None, it will be equal to the
                                      aws_object_key.
    :type azure_storage_blob_overwrite: bool
    :param azure_storage_blob_overwrite => If there is already a blob with the
                                           azure_storage_blob_name, the
                                           original file could be re-written
                                           or and ID is generated that will
                                           differentiate the names of the
                                           blobs. By default the files aren't
                                           overwritten.
    :type information: dict
    :return information => Returns a dict with the basic information of the
                           transfer
    """
    # accessing the AWS bucket
    s3_client = get_s3_client(
        aws_access_key_id=aws_access_key_id,
        aws_secret_access_key=aws_secret_access_key,
        aws_storage_bucket_name=aws_storage_bucket_name,
    )

    if azure_storage_blob_name is None:
        azure_storage_blob_name = aws_object_key

    # generating the URLs for the S3 object
    if aws_public_object is True:
        # simple URL for public objects
        object_url = (
            'https://s3.amazonaws.com/'
            f'{aws_storage_bucket_name}/'
            f'{aws_object_key}/'
        )
    else:
        # try and catch error for the creation of the signed URL of the
        # uploaded file in case this file is private
        try:
            object_url = s3_client.generate_presigned_url(
                "get_object",
                params={
                    "Bucket": aws_storage_bucket_name,
                    "key": aws_object_key,
                },
                ExpiresIn=aws_url_expiration_time
            )
        except ClientError as e:
            print(e)
            return
    # accesing AzureStorage
    blob_client = get_azure_blob_client(
        azure_storage_container_name=azure_storage_container_name,
        azure_storage_blob_name=azure_storage_blob_name,
        azure_storage_account_name=azure_storage_account_name,
        azure_storage_access_key=azure_storage_access_key,
        azure_storage_connection_string=azure_storage_connection_string,
    )
    # checker and deleter existing blobs with the same name
    # if overwrite is true, we delete the possible coincidence and create a new
    # blob
    if azure_storage_blob_overwrite is True:
        if blob_client.exists():
            blob_client.delete_blob()
    # if overwrite is false, we generate and ID to put on the name and we
    # change it until the uniqueness condition is meet
    else:
        original_name = azure_storage_blob_name
        exists = blob_client.exists()
        while exists is True:
            file_name, file_extension = os.path.splitext(original_name)
            random_id = id_generator()
            azure_storage_blob_name = (
                f"{file_name}"
                "_"
                f"{random_id}"
                f"{file_extension}"
            )
            blob_client = get_azure_blob_client(
                azure_storage_container_name=azure_storage_container_name,
                azure_storage_blob_name=azure_storage_blob_name,
                azure_storage_account_name=azure_storage_account_name,
                azure_storage_access_key=azure_storage_access_key,
                azure_storage_connection_string=azure_storage_connection_string,
            )
            exists = blob_client.exists()

    # creating the request for the requests package
    object_stream = requests.get(object_url, stream=True)
    blob_client.upload_blob(object_stream)
    print(
        "Finalized process for: \n"
        f"Azure Storage Container: {azure_storage_container_name} \n"
        f"Azure Blob Name: {azure_storage_blob_name} \n"
    )
    # deleting the original object if conditional
    if aws_delete_after_transfer is True:
        s3_client.delete_object(
            Bucket=aws_storage_bucket_name,
            Key=aws_object_key,
        )
        print(
            "Object deleted from origin: \n"
            f"S3 Object Key: {aws_object_key} \n"
            f"S3 Bucket Name: {aws_storage_bucket_name} \n"
        )
    information = {
        "azure_storage_container_name": azure_storage_container_name,
        "azure_storage_blob_name": azure_storage_blob_name,
        "aws_storage_bucket_name": aws_storage_bucket_name,
        "aws_storage_object_key": aws_object_key,
    }
    return information
```

[1]: https://docs.microsoft.com/en-us/azure/storage/common/storage-ref-azcopy
