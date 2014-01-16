#
# Cookbook Name:: eacustom
# Recipe:: fix_java_version
#
# Copyright (C) 2014 YOUR_NAME
# 
# All rights reserved - Do Not Redistribute
#
execute "fix_java_version" do
  command "alternatives --set java /usr/lib/jvm/jre-1.7.0-openjdk.x86_64/bin/java"
end