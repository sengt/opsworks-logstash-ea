# A complete Logstash stack on AWS OpsWorks

This is a modified version of the [Springtest](https://github.com/springtest/opsworks-logstash) project.

In particular, the goal is to (where possible) avoid forking dependencies and instead wrap them to get any desired OpsWorks behavior.

* **kibana** -> now using "vanilla" `kibana` cookbook, with wrapping done by an `opsworks-kibana` recipe
* **elasticsearch** -> still using forked version
* **logstash** -> now using "semi-official" `/lusis/logstash` cookbook

# Kibana, Elasticsearch & Logstash

We're going to end up creating three separate layers in our OpsWorks stack:

* Kibana - web frontend for viewing logs
* Elasticsearch - log storage, indexing, querying
* Logstash - log collection

For these instructions, we're assuming that you're using SQS as a broker and will demonstrate configuring the Logstash agents appropriately. If this isn't the case, the Kibana and Elasticsearch configuration will remain the same, but you'll need to modify the Logstash parts.

## EC2 Setup

Before diving into OpsWorks, you'll need to do a bit of setup in the *EC2* area of AWS.

### Securing the Stack

By default, Elasticsearch does not require authentication to make requests. It is possible to enable Basic http auth, but this covers only the REST API, and (because it's not a fully-compliant implementation of Basic auth) also prevents some web-based plugins from working. It's better to think of Elasticsearch as a backend database and secure it as such.

What we want to end up with is:

* Kibana - available via ssh and http on the public internet, secured by HTTP Basic auth
* Elasticsearch - available via ssh on the public internet, otherwise only reachable by Kibana and Logstash instances
* Logstash - available only via ssh on the public internet

We're going to accomplish this with a very basic VPC setup and some security groups. You could go further and put Elasticsearch and Logstash into a private subnet with appropriate NAT rules.

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

## OpsWorks

### Stack Setup

On the OpsWorks dashboard, select "Add Stack". Most default values are fine (or you can change things like regions or availability zones to suit your needs), but make sure to set:

* **VPC** -> Select the VPC you created earlier
* **Default operating system** -> Elasticsearch wants Amazon Linux, while Kibana and logstash will run on Ubuntu, so there's no right answer here; you'll have to customize this when you bring up instances
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
    "elasticsearch": {
        "version":"0.90.9",
        "cluster": {
            "name": "logstash"
        }
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
    }
}
```

If you're using SQS as a broker, include the snippet below as well (after the "kibana" block). If you're *not* using SQS, you'll still likely need a `logstash` element with config, but its contents will be dependent on your specific scenario.

```json
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
                        "use_ssl": "false"
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

Then configure them:
### Elasticsearch
* Custom Chef Recipes
 * **Setup** - `elasticsearch::packages`, `java`,`elasticsearch::install`
 * **Configure** - `elasticsearch`
* Elastic Load Balancing
 * Select the load balancer you created previously
* EBS Volumes
 * **EBS optimized instances** - No
 * Add an EBS volume mounted at `/data`. Set the RAID level and size based on your needs
* Automatically Assign IP Addresses
 * Public IP Addresses: Yes
 * Elastic IP Addresses: No
* Security Groups
 * **Additional Groups** - `default`

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

Then launch some instances.

_Remember that Elasticsearch instances need to use Amazon Linux, while Kibana and Logstash should use Ubuntu_

# Try It Out

Assuming you're using SQS, you can post messages to the queue directly using Amazon's web UI. If everything is working properly, you should see it arrive in the Kibana dashboard shortly thereafter.
