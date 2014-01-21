# A complete Logstash stack on AWS OpsWorks

This is a slightly modified version of the [Springtest](https://github.com/springtest/opsworks-logstash) project.

In particular, the goal is to (where possible) avoid forking dependencies and instead wrap them to get any desired OpsWorks behavior.

* **kibana** -> now using "vanilla" `kibana` cookbook, with wrapping done by an `opsworks-kibana` recipe
* **elasticsearch** -> still using forked version
* **logstash** -> still using forked version

# Elasticsearch & Kibana

Before diving into OpsWorks, you'll need to do a bit of setup in the *EC2* area of AWS.

## EC2 Setup

### Security Groups

Create an `elasticsearch` security group allowing inbound traffic on ports
* 22 (for ssh access)
* 9200 (for elasticsearch REST API access)
* 9300 (for elasticsearch API access)

### Load-balancer

Create a load balancer. Under the "Listeners" tab, set it up to forward ports:
* TCP 9200 -> TCP 9200
* TCP 9300 -> TCP 9300

### Key Pair

If you have an existing ssh key pair you want to use, that's fine. Otherwise, create a new one.

## SQS Setup

If you're planning on using Amazon's SQS as a "broker" between log producers and Elasticsearch, you'll need to configure a queue for this purpose and IAM users to read and write from the queue.

You can just use default values when creating a queue. Make a note of the ARN of your new queue.

### IAM Setup

Create two users in IAM called `logstash-reader` and `logstash-writer`.

Assign `logstash-writer` the policy below:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Stmt1389301427000",
      "Effect": "Allow",
      "Action": [
        "sqs:SendMessage"
      ],
      "Resource": [
        "{ARN of your queue, eg. arn:aws:sqs:us-east-1:000000000:logstash}"
      ]
    }
  ]
}
```

Assign `logstash-reader` the policy below:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Stmt1389733069000",
      "Effect": "Allow",
      "Action": [
        "sqs:ChangeMessageVisibility",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ListQueues",
        "sqs:ReceiveMessage"
      ],
      "Resource": [
        "{ARN of your queue, eg. arn:aws:sqs:us-east-1:000000000:logstash}"
      ]
    }
  ]
}
```

Create an Access Key for `logstash-reader` and make a note of it. You'll need to put it in your custom Chef json (discussed below).

## OpsWorks

### Stack Setup

On the OpsWorks dashboard, select "Add Stack". Most default values are fine (or you can change things like regions or availability zones to suit your needs), but make sure to set:

* **Default operating system** -> Elasticsearch wants Amazon Linux, while Kibana and logstash will run on Ubuntu, so there's no right answer here; you'll have to customize this when you bring up instances
* Under the "Advanced" settings:
 * **Chef version** -> 11.4
 * **User custom Chef cookbooks** -> Yes
 * **Custom Chef Json** -> See below

### Custom Chef Json

The custom json below will configure your Kibana and Elasticsearch layers. Make sure to fill in appropriate values for things like `{some user name}`.

```json
{
    "chef_environment": "production",
    "java": {
        "jdk_version":7,
        "install_flavor":"openjdk"
    },
    "opsworks-kibana": {
        "web_auth_enabled": true,
        "web_user": "{some user name}", //this is how you'll log into your logs dashboard
        "web_password": "{super secret password}"
    },
    "elasticsearch": {
        "version":"0.90.9",
        "cluster": {
            "name": "logstash"
        },
        "basic_auth": {
            "user": "{some user name}",
            "password": "{super secret password}"
        }
    },
    "kibana": {
        "webserver": "nginx",
        "webserver_hostname": "logs.example.com", //this value isn't super critical if you don't have a nice hostname
        "es_port": "9200",
        "es_role": "elasticsearch",
        "es_server": "{public address of your ELB}",
        "es_user": "{some user name}",
        "es_password": "{super secret password}",
        "config_cookbook": "opsworks-kibana",
        "nginx": {
            "template_cookbook": "opsworks-kibana"
         } 
    }
}
```

If you're using SQS as a broker, include the snippet below as well (after the "kibana" block). If you're *not* using SQS, you'll still likely need a `logstash` element with config, but its contents will be dependent on your specific scenario.

```json
    "logstash": {
        "elasticsearch_cluster": "logstash",
        "server": {
            "install_rabbitmq": false,
            "enable_embedded_es": false,
            "version":"1.4.0.dev",
            "source_url": "https://tnt-public-lib.s3.amazonaws.com/logstash/logstash-1.4.0.dev-flatjar.jar",
            "elasticsearch_role": "elasticsearch",
            "inputs": [
                {
                    "sqs": {
                        "access_key_id": "{access key id for logstash reader}",
                        "secret_access_key": "{secret access key for logstash reader}",
                        "queue": "{name of your logstash queue}",
                        "region": "us-east-1",
                        "threads": 25,
                        "use_ssl": "false"
                    }
                }
            ]
        }
    }
```

### Layer Configuration

Add some layers to your stack:

* Elasticsearch
 * **Layer type** - Custom
 * **Name** - Elasticsearch
 * **Short name** - elasticsearch
* Kibana
 * **Layer type** - Custom
 * **Name** - Kibana
 * **Short name** - kibana
* Logstash
 * **Layer type** - Custom
 * **Name** - Logstash
 * **Short name** - logstash
* RabbitMQ
 * **Layer type** - Custom
 * **Name** - RabbitMQ
 * **Short name** - RabbitMQ

(the RabbitMQ layer will never have any instances added to it, but is necessary to work around a bug in the logstash Chef recipe we're using; we'll remove this requirement in a future release)

Then configure them:
### Elasticsearch
* Custom Chef Recipes
 * **Setup** - `elasticsearch::packages`, `java`, `eacustom::fix_java_version`,`elasticsearch::install`
 * **Configure** - `elasticsearch`
* Elastic Load Balancing
 * Select the load balancer you created previously
* EBS Volumes
 * **EBS optimized instances** - No
 * Add an EBS volume mounted at `/data`. Set the RAID level and size based on your needs
* Security Groups
 * **Additional Groups** - `elasticsearch`

#### Kibana
* Custom Chef Recipes
 * **Setup** - `opsworks-kibana`

#### Logstash
* Custom Chef Recipes
 * **Setup** - `logstash::server`, `java`

Then launch some instances.

_Remember that Elasticsearch instances need to use Amazon Linux, while Kibana and Logstash should use Ubuntu_

# Try It Out

Assuming you're using SQS, you can post messages to the queue directly using Amazon's web UI. If everything is working properly, you should see it arrive in the Kibana dashboard shortly thereafter.
