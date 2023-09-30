---
title: File Transfer Between Cloud Services (AWS to Azure)
date: 2023-02-15T12:00:00-05:00
draft: false

read_more: Read more...
tags: ["python", "AWS", "Azure"]
categories: ["programming"]
---

Sometimes is a requirement to transfer files from one cloud service to another.
At least that was the challenge that I encountered while developing a file
classification web service. Mid development cycle management changed cloud
provider because of some juicy Azure discounts and the all so great office 365
integration that everyone loves.

Because of this, the compromise reached to be able to continue at the same
development speed and still lower the cloud services bill, was to continue to
work on AWS in the web service, but the files, after finished the process, must
be transferred to Azure.

With all the restrictions regarding failure upon transfer and other things,
there are two that are the most relevant for this particular case, which are:

* The server can’t download the full files from S3. Some of the files are in
  the realm of hundreds of gigabytes and the server instance that we are
  currently using, cannot scale up the harddrive to that capacity without
  leaving us broke.

* We should be able to send several files at the same time.

After much thinking and going back and forward with the team, got the idea to
request the file through a stream of data, and then upload it chunk by chunk
into the cloud. In that way the only part of the file that we will have in our
harddrive is the current chunk of the file that we are transferring but nothing
more.

The requirements to implement this code, are the packages and the Python
version which I was working with at the time. Also is expected a basic
knowledge of AWS S3 and Azure APIs.

```toml
[packages]
  boto3 = "==1.21"
  azure-storage-blob = "==12.10"
  requests = "==2.27"

[requires]
  python_version = "3.9"
```

For azure, there is a CLI tool called [azcopy][1], from Microsoft that allows
for multithreaded parallel download and upload of files, and given the
restrictions of your own problem is worth checking out. In our case, the tool
still needs to have the file in the hard-drive, which as we said before is
something we cannot have.

As a start we need the azure blob client for the container and the destination
file that we are going to create.

```python
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
```

Now for the AWS S3 client we have:

```python
aws_session = boto3.session(
    aws_access_key_id=aws_access_key_id,
    aws_secret_access_key=aws_secret_access_key
)

s3_client = aws_session.client('s3')
```

In case the files are private, you need to take into account that we have to
generate a public URL. In AWS the maximum amount of time that a pre signed url
of the object has is 7 days, which are 604800 seconds. If the file can’t be
downloaded and transferred in the 7 days, the file will remain as a partial
transfer. In our case the biggest file needed a 4 day continuous stream to
fully transfer.

```python
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
upload it to the Azure blob client.

When we request a file as a stream, what is returned is an iterable object that
the blob uploader takes and upload one chunk at a time in an ordered manner.

```python
object_stream = requests.get(object_url, stream=True)
blob_client.upload_blob(object_stream)
```

And with this solution we were able to seamlessly transfer all the files from
one provider to another, without slowing down our work, and still benefiting
with the lower bill for storage.

[1]: https://docs.microsoft.com/en-us/azure/storage/common/storage-ref-azcopy
