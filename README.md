# A complete Logstash stack on AWS OpsWorks

This set of cookbooks began as a fork of the [Springtest](https://github.com/springtest/opsworks-logstash) project, but has been updated to use "official" cookbooks (with customized "wrapper" cookbooks where necessary), rather than creating forked dependencies.

Specifically:

* **kibana** -> uses "vanilla" `kibana` cookbook, with wrapping done by an `opsworks-kibana` recipe
* **elasticsearch** -> uses the official cookbook from Elasticsearch
* **logstash** -> uses the "semi-official" `/lusis/logstash` cookbook

# Kibana, Elasticsearch & Logstash

We're going to end up creating three separate layers in an OpsWorks stack:

* Kibana - web frontend for viewing logs; basically just an Nginx proxy to the Elasticsearch layer
* Elasticsearch - log storage, indexing, querying
* Logstash - log collection

For these instructions, we're assuming that you're using SQS as a broker and will demonstrate configuring the Logstash agents appropriately. If this isn't the case, the Kibana and Elasticsearch configuration will remain the same, but you'll need to modify the Logstash parts.

## EC2 Setup

Before diving into OpsWorks, you'll need to do a bit of setup in the *EC2* area of AWS.

### Securing the Stack

By default, Elasticsearch does not require authentication to make requests. It is possible to enable Basic http auth, but this covers only the REST API, and also prevents some web-based plugins from working properly. It's better to think of Elasticsearch as a backend database and secure it as such.

What we want to end up with is:

* Kibana - available via ssh and http on the public internet, secured by HTTP Basic auth
* Elasticsearch - available via ssh on the public internet, otherwise only reachable by Kibana and Logstash instances
* Logstash - available only via ssh on the public internet

We're going to accomplish this with a very basic VPC setup and some security groups. You could go further and put Elasticsearch and Logstash into a private subnet with appropriate NAT rules, but that requires a more involved VPC setup.

#### Create VPC

Go to the **VPC** dashboard and click `Start VPC Wizard`. Select **VPC with a Single Public Subnet Only**, and then just click through until the VPC has been created.

It's probably a good idea to create a "Name" tag for your VPC, as it can be tricky to keep track of which one is which once you've created several.

#### Configure Security Groups

Go to the **Security Groups** section (in the **VPC** area, not the regular **EC2** one). There should already be a `default` security group defined with a single rule allowing all instances within the group to talk to each other. To additionally enable ssh access, you can add an inbound rule allowing traffic on port 22.

```
TCP Port      Source
--------      ------
ALL           sg-xxxxxxxx (ID of the default security group)
22 (SSH)      0.0.0.0/0
```

We additionally want to create a `Kibana` security group that will allow web traffic to the Kibana dashboard.

```
TCP Port      Source
--------      ------
22 (SSH)      0.0.0.0/0
80 (HTTP)     0.0.0.0/0
443 (HTTPS)   0.0.0.0/0
```

**Note:** For both security groups, ssh access is typically only required for debugging purposes. If you want to really lock things down, you can remove the SSH rules from the groups (changes you make to a security group take effect immediately; you don't need to restart any affected instances).

#### Create Elasticsearch Load Balancer

Next, we want to be able to put an ELB in front of our Elasticsearch array. We'll create an *internal* ELB in our VPC; Kibana and Logstash instances will be able to talk to it, but it will be inaccessable to the outside world.

In the EC2 dashboard, create a new ELB
```
Load Balancer Name: <name>
Create LB inside: <id of your VPC>
Create an internal load balancer: yes
```

**Listener Configuration:**
```
HTTP 9200 -> HTTP 9200
TCP 9300 -> TCP 9300
```
**Configuration Options:**
```
Ping Protocol: HTTP
Ping Port: 9200
Ping Path: /
```

**Selected Subnets:**

* select all of the subnets you created in your VPC

**Security Groups:**

* Chose from your existing Security Groups
  * find the `default` security group and select it

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

We're also going to take advantage of IAM Roles and Instance Profiles. Also in IAM, create a Role called `logstash-elasticsearch-instance` with the policy below:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Stmt1393205558000",
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteSnapshot",
        "ec2:DeleteVolume",
        "ec2:DescribeSnapshotAttribute",
        "ec2:Describe*",
        "ec2:DetachVolume",
        "ec2:EnableVolumeIO",
        "ec2:ImportVolume",
        "ec2:ModifyVolumeAttribute"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
```
We'll use this role later when setting up our Elasticsearch layer in OpsWorks.

## OpsWorks

### Stack Setup

On the OpsWorks dashboard, select "Add Stack". Most default values are fine (or you can change things like regions or availability zones to suit your needs), but make sure to set:

* **VPC** -> Select the VPC you created earlier
* **Default operating system** -> Ubuntu
* Under the "Advanced" settings:
 * **Chef version** -> 11.4
 * **User custom Chef cookbooks** -> Yes
 * **Repository URL** -> `URL you got this from`
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
    "kibana": {
        "webserver": "nginx",
        "webserver_hostname": "logs.example.com", //this value isn't super critical if you don't have a nice hostname
        "es_port": "9200",
        "es_role": "elasticsearch",
        "es_server": "{address of your Elasticsearch ELB}",
        "config_cookbook": "opsworks-kibana",
        "nginx": {
            "template_cookbook": "opsworks-kibana"
         } 
    },
    "elasticsearch": {
        "version": "0.90.9",
        "cluster": {
            "name": "logstash"
        },
        "discovery": {
            "type": "ec2",
            "ec2": {
                "tag": {
                    "opsworks:stack": "{name-of-your-OpsWorks-stack}",
                    "opsworks:layer:elasticsearch": "{name-of-your-Elasticsearch-layer}"
                }
            }
        },
        "plugins": {
            "karmi/elasticsearch-paramedic": {},
            "royrusso/elasticsearch-HQ": {}
        },
        "data": {
            "devices": {
                "/dev/xvdi": {
                    "file_system": "ext3",
                    "mount_options": "rw,user",
                    "mount_path": "/usr/local/var/data/elasticsearch",
                    "format_command": "mkfs.ext3",
                    "fs_check_command": "dumpe2fs",
                    "ebs": {
                        "size": `{amount of space in gb you want for log storage}`,
                        "delete_on_termination": true,
                        "type": "standard"
                    }
                }
            }
        }
    },
    "logstash": {
        "elasticsearch_cluster": "logstash",
        "agent": {
            "version": "1.3.3",
            "source_url": "https://download.elasticsearch.org/logstash/logstash/logstash-1.3.3-flatjar.jar",
            "inputs": [
                {
                    "sqs": {
                        "access_key_id": "{access key id for logstash reader}",
                        "secret_access_key": "{secret access key for logstash reader}",
                        "queue": "{name of your logstash queue}",
                        "region": "us-east-1",
                        "threads": 25,
                        "use_ssl": "false",
                        "codec": "json"
                    }
                }
            ],
            "outputs": [
                {
                    "elasticsearch": {
                        "host": "{address of your Elasticsearch ELB}",
                        "cluster": "logstash"
                    }
                }
            ]
        }
    }
}
```

This setup assumes you're using SQS as a broker in your logstash layer; if you're not, you'll need to modify the `input` settings for the `logstash` section.

The `elasticsearch` config will create and mount an EBS volume sized as large as you want. By default, it will delete the volume if you terminate the instance. Keep that in mind before you terminate the last instance in your cluster and lose all your logs!

We also install both [Elasticsearch-HQ]() and [Paramedic]() as examples of how to install plugins. If you don't want to use these plugins, you can remove them from the `plugins` section (or remove the `plugins` section altogether).

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

Then configure them:
### Elasticsearch
* Custom Chef Recipes
 * **Setup** - `java`, `elasticsearch`, `elasticsearch::ebs`, `elasticsearch::data`, `elasticsearch::aws`, `elasticsearch::plugins`
* Elastic Load Balancing
 * Select the load balancer you created previously
* EBS Volumes
 * **EBS optimized instances** - No
* Automatically Assign IP Addresses
 * Public IP Addresses: Yes
 * Elastic IP Addresses: No
* Security Groups
 * **Additional Groups** - `default`
* IAM Instance Profile
 * **Layer Profile**: `logstash-elasticsearch-instance` - this is the role we created in IAM previously

#### Kibana
* Custom Chef Recipes
 * **Setup** - `opsworks-kibana`
* EBS Volumes
 * **EBS optimized instances** - No
* Automatically Assign IP Addresses
 * Public IP Addresses: Yes
 * Elastic IP Addresses: No
* Security Groups
 * **Additional Groups** - `default`, `kibana`

#### Logstash
* Custom Chef Recipes
 * **Setup** - `java`, `logstash::agent`
* EBS Volumes
 * **EBS optimized instances** - No
* Automatically Assign IP Addresses
 * **Public IP Addresses:** Yes
 * **Elastic IP Addresses:** No
* Security Groups
 * **Additional Groups** - `default`

Then launch some instances!

# Try It Out

Assuming you're using SQS, you can post messages to the queue directly using Amazon's web UI. If everything is working properly, you should see it arrive in the Kibana dashboard shortly thereafter.
