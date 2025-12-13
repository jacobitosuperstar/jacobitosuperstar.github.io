---
title: Transferencia de archivos entre servicios en la nube (AWS a Azure)
date: 2023-02-15T12:00:00-05:00
draft: false

read_more: Leer más...
tags: ["python", "AWS", "Azure"]
categories: ["programación"]
---

A veces es un requisito transferir archivos de un servicio en la nube a otro.
Al menos ese fue el desafío que encontré mientras desarrollaba un servicio web
de clasificación de archivos. A mitad del ciclo de desarrollo, la gerencia
cambió de proveedor de nube debido a algunos jugosos descuentos de Azure y la
tan grandiosa integración de office 365 que todos aman.

Debido a esto, el compromiso alcanzado para poder continuar a la misma
velocidad de desarrollo y aún así reducir la factura de servicios en la nube,
fue continuar trabajando en AWS en el servicio web, pero los archivos, después
de finalizado el proceso, deben ser transferidos a Azure.

Con todas las restricciones respecto a fallas en la transferencia y otras
cosas, hay dos que son las más relevantes para este caso particular, las cuales
son:

* El servidor no puede descargar los archivos completos de S3. Algunos de los
  archivos están en el rango de cientos de gigabytes y la instancia del
  servidor que estamos usando actualmente, no puede escalar el disco duro a esa
  capacidad sin dejarnos en bancarrota.

* Deberíamos poder enviar varios archivos al mismo tiempo.

Después de mucho pensar e ir y venir con el equipo, surgió la idea de solicitar
el archivo a través de un flujo de datos, y luego subirlo fragmento por
fragmento a la nube. De esa manera la única parte del archivo que tendremos en
nuestro disco duro es el fragmento actual del archivo que estamos transfiriendo
pero nada más.

Los requisitos para implementar este código, son los paquetes y la versión de
Python con la que estaba trabajando en ese momento. También se espera un
conocimiento básico de las APIs de AWS S3 y Azure.

```toml
[packages]
  boto3 = "==1.21"
  azure-storage-blob = "==12.10"
  requests = "==2.27"

[requires]
  python_version = "3.9"
```

Para Azure, hay una herramienta CLI llamada [azcopy][1], de Microsoft que
permite la descarga y carga de archivos multihilo en paralelo, y dadas las
restricciones de tu propio problema, vale la pena revisarla. En nuestro caso,
la herramienta todavía necesita tener el archivo en el disco duro, lo cual como
dijimos antes es algo que no podemos tener.

Para empezar necesitamos el cliente de blob de Azure para el contenedor y el
archivo de destino que vamos a crear.

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

Ahora para el cliente de AWS S3 tenemos:

```python
aws_session = boto3.session(
    aws_access_key_id=aws_access_key_id,
    aws_secret_access_key=aws_secret_access_key
)

s3_client = aws_session.client('s3')
```

En caso de que los archivos sean privados, necesitas tener en cuenta que
tenemos que generar una URL pública. En AWS la cantidad máxima de tiempo que
una URL pre-firmada del objeto tiene es de 7 días, que son 604800 segundos. Si
el archivo no puede ser descargado y transferido en los 7 días, el archivo
permanecerá como una transferencia parcial. En nuestro caso el archivo más
grande necesitó un flujo continuo de 4 días para transferirse completamente.

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

Luego tenemos que crear el flujo del archivo que estamos solicitando, y subirlo
al cliente de blob de Azure.

Cuando solicitamos un archivo como un flujo, lo que se devuelve es un objeto
iterable que el cargador de blob toma y sube un fragmento a la vez de manera
ordenada.

```python
object_stream = requests.get(object_url, stream=True)
blob_client.upload_blob(object_stream)
```

Y con esta solución pudimos transferir sin problemas todos los archivos de un
proveedor a otro, sin desacelerar nuestro trabajo, y aún así beneficiándonos
con la factura más baja para el almacenamiento.

[1]: https://docs.microsoft.com/en-us/azure/storage/common/storage-ref-azcopy
