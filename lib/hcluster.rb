#!/usr/bin/env ruby
require 'monitor'
require 'net/ssh'
require 'net/scp'
#For development purposes..
#..uncomment this: ..
#gem 'amazon-ec2', '>= 0.9.15'
require 'AWS'
require 'aws/s3'

ROOT_DIR   = File.dirname(__FILE__) + '/..'

if ENV['AWS_ENDPOINT'] != nil
  ENDPOINT = ENV['AWS_ENDPOINT']
else
  ENDPOINT = "ec2.amazonaws.com"
end

def pretty_print(hash)
  retval = ""
  hash.keys.each{|key|
    retval = retval + " :#{key} => #{hash[key]}\n"
  }
  return retval
end

module Hadoop

  class Himage < AWS::EC2::Base
    attr_reader :label,:image_id,:image,:shared_base_object, :owner_id

    @@owner_id = ENV['AWS_ACCOUNT_ID'].gsub(/-/,'')

    def Himage::owner_id
      @@owner_id
    end

    def owner_id
      @@owner_id
    end

    begin
      @@shared_base_object = AWS::EC2::Base.new({
          :access_key_id => ENV['AWS_ACCESS_KEY_ID'],
          :secret_access_key => ENV['AWS_SECRET_ACCESS_KEY'],
          :server => ENDPOINT
        })
    rescue
      puts "ooops..maybe you didn't define AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY? "
    end

    @@s3 = AWS::S3::S3Object

    if !(@@s3.connected?)
      @@s3.establish_connection!(
          :access_key_id => ENV['AWS_ACCESS_KEY_ID'],
          :secret_access_key => ENV['AWS_SECRET_ACCESS_KEY'],
          :server => ENDPOINT
        )
    end

    def list
      Himage::list
    end

    def Himage::s3
      @@s3
    end

    def upload(bucket,file)
      filename = File.basename(file)
      puts "storing '#{filename}' in s3 bucket '#{bucket}'..\n"
      begin
        @@s3.store filename, open(file), bucket,:access => :public_read
      rescue RuntimeError => e
        raise "Upload of '#{file}' failed '(#{e.message})': please retry."
      end
      puts "upload('#{bucket}','#{file}') is done."
    end

    def Himage::myimages_print(options = {})
      myimages(options) and nil
    end

    def Himage::myimages(options = {})
      options = {
        :owner_id => Himage::owner_id
      }.merge(options)
      Himage::list(options)
    end

    def Himage::list(options = {})
      options = {
        :all => false,
        :output_fn => lambda{|line|
          puts line
        }
      }.merge(options)


      if options[:label]
        imgs = describe_images(options)
      else
        imgs = HCluster.describe_images(options).imagesSet.item
      end

      if options[:output_fn]
        if (imgs)
          options.output_fn.call "label\t\t\t\tami\t\t\towner_id\t\t\t"
          options.output_fn.call "================================================================"
          debug = false
          imgs.each {|image| 
            if debug == true
              puts "#{pretty_print(image)}"
            end
            options.output_fn.call "#{image.name}\t\t#{image.imageId}\t\t#{image.imageOwnerId}"
          }
          options.output_fn.call ""
        end
      end
      # in either case return the array of image structures
      imgs
    end

    def initialize_himage_usage
      puts ""
      puts "Himage.new usage"
      puts "  options: (description) (default, if any)"
      puts "   :tar_s3 (name of S3 bucket where tarfiles should be stored)"
      puts "   :ami_s3 (name of S3 bucket where AMIs should be stored)"
      puts "   :hadoop (full path to hadoop tar.gz archive)"
      puts "   :hbase  (full path to hbase tar.gz archive)"
      puts " ==== or === "
      puts "   :hadoop_url (path in S3 to hadoop tar.gz archive)"
      puts "   :hbase_url (path in S3 to hbase tar.gz archive)"
      puts "   :tar_s3 (name of S3 bucket where tarfiles should be stored)"
      puts "   :ami_s3 (name of S3 bucket where AMIs should be stored)"
      puts ""
    end

    def initialize(options = {})
      @shared_base_object = @@shared_base_object
      @owner_id = @@owner_id
      options = {
        :owner_id => @@owner_id,
        :hadoop_url => nil,
        :hbase_url => nil
      }.merge(options)

      if (options[:hadoop_url] and options[:hbase_url] and options[:tar_s3] and options[:ami_s3])
        @hadoop_url = options[:hadoop_url]
        @hbase_url = options[:hbase_url]
        @hadoop_filename = File.basename(options[:hadoop_url])
        @hbase_filename = File.basename(options[:hbase_url])
        @tar_s3 = options[:tar_s3]
        @ami_s3 = options[:ami_s3]
      else
        if options[:hbase] && options[:hadoop] && options[:tar_s3] && options[:ami_s3]
          # verify existence of these two files.
          raise "HBase tarfile: #{options[:hbase]} does not exist or is not readable" unless File.readable? options[:hbase]
          raise "Hadoop tarfile: #{options[:hadoop]} does not exist or is not readable" unless File.readable? options[:hadoop]
          @hadoop = options[:hadoop]
          @hbase = options[:hbase]
          @tar_s3 = options[:tar_s3]
          @ami_s3 = options[:ami_s3]
          @hadoop_filename = File.basename(options[:hadoop])
          @hbase_filename = File.basename(options[:hbase])
          @hadoop_url = "http://#{@tar_s3}.s3.amazonaws.com/#{@hadoop_filename}"
          @hbase_url = "http://#{@tar_s3}.s3.amazonaws.com/#{@hbase_filename}"
        else
          #not enough options: show usage and exit.
          initialize_himage_usage
          raise HImageError, "required information missing: see usage information above."
        end
        puts "Uploading tarballs required for building this image."
        upload_tars
      end


    end

    # Warning: uploaded tars must be world-readable for the build script (below)
    # to access them. Do not store sensitive information in the tarballs.
    def keep_trying_to_upload(file_to_upload,bucket)
      uploaded = false
      until uploaded == true
        begin
          retval = AWS::S3::S3Object.store(
                                           File.basename(file_to_upload),
                                           open(file_to_upload),
                                           bucket,
                                           :access => :public_read)
        rescue IOError => e
          puts "IOError happened uploading '#{file_to_upload}' ('#{e.message}'): retrying.\n"
        else
          puts "#{file_to_upload} uploaded.\n"
          uploaded = true
        end
      end
    end

    def upload_tars
      puts "starting upload..."
      hbase_thread = Thread.new do
        keep_trying_to_upload(@hbase,@tar_s3)
      end

      hadoop_thread = Thread.new do
        keep_trying_to_upload(@hadoop,@tar_s3)
      end
      
      begin
        hbase_thread.join
      rescue NoMethodError => e
        puts "ignoring 'NoMethodError' '(#{e.message})'."
      end

      begin
        hadoop_thread.join
      rescue NoMethodError => e
        puts "ignoring 'NoMethodError' '(#{e.message})'."
      end

      puts "Tarballs uploaded. You can now call 'create_image' on this object."
    end

    # ami-b00c34d9 => rightscale-us-east/RightImage_CentOS_5.4_x64_v5.4.6.2_Beta.manifest.xml
    def create_image(options = {})
      options = {
        :debug => false,
        :base_ami_image => 'ami-b00ce4d9',
        :arch => "x86_64",
        :delete_existing => false
      }.merge(options)
      #FIXME: check for existence of tarfile URLs: if they don't exist, either raise exception or call upload_tars().
      #..
      #FIXME: check for existence of @ami_s3 and @tar_s3 buckets.
      #

      image_label = "hbase-#{HCluster.label_to_hbase_version(File.basename(@hbase_filename))}-#{options[:arch]}"

      existing_image = Himage.find_owned_image :label => image_label
      if existing_image[0]
        if options[:delete_existing] == true
          puts "Warning: de-registering existing AMI: '#{existing_image[0].imageId}'."
          Himage.deregister(existing_image[0].imageId)
        else
          puts "Existing image: '#{existing_image[0].imageId}' already registered for image named '#{image_label}'. Call Himage.deregister('#{existing_image[0].imageId}'), if desired."
          return existing_image[0].imageId
        end
      end

      puts "Creating and registering new image named: #{image_label}"
      puts "Starting a builder AMI with ID: #{options[:base_ami_image]}.."
      
      launch = HCluster::do_launch({
                                     :ami => options[:base_ami_image],
                                     :key_name => "root",
                                     :instance_type => "m1.large"
                                   },"image-creator")
      
      if (launch && launch[0])
        @image_creator = launch[0]
      else 
        raise "Could not launch image creator."
      end
      
      image_creator_hostname = @image_creator.dnsName
      
      HCluster::until_ssh_able([@image_creator])
      image_creator_hostname = @image_creator.dnsName
      puts "Copying scripts.."
      HCluster::scp_to(image_creator_hostname,"#{ROOT_DIR}/bin/functions.sh","/mnt")
      HCluster::scp_to(image_creator_hostname,"#{ROOT_DIR}/bin/image/create-hbase-image-remote","/mnt")
      HCluster::scp_to(image_creator_hostname,"#{ROOT_DIR}/bin/image/ec2-run-user-data","/etc/init.d")
      
      # Copy private key and certificate (for bundling image)
      HCluster::scp_to(image_creator_hostname, EC2_ROOT_SSH_KEY, "/mnt")
      HCluster::scp_to(image_creator_hostname, EC2_CERT, "/mnt")

      hbase_version = HCluster.label_to_hbase_version(File.basename(@hbase_filename))
      hadoop_version = HCluster.label_to_hbase_version(File.basename(@hadoop_filename))
      lzo_url = "http://tm-files.s3.amazonaws.com/hadoop/lzo-linux-0.20-tm-2.tar.gz"
      java_url = "http://mlai.jdk.s3.amazonaws.com/jdk-6u20-linux-#{options[:arch]}.bin"
      ami_bucket = @ami_s3

      image_creator_hostname = @image_creator.dnsName

      puts "Building image.."

      sh = "sh -c \"ARCH=#{options[:arch]} HBASE_VERSION=#{hbase_version} HADOOP_VERSION=#{hadoop_version} HBASE_FILE=#{@hbase_filename} HBASE_URL=#{@hbase_url} HADOOP_URL=#{@hadoop_url} LZO_URL=#{lzo_url} JAVA_URL=#{java_url} AWS_ACCOUNT_ID=#{@@owner_id} S3_BUCKET=#{@ami_s3} AWS_SECRET_ACCESS_KEY=#{ENV['AWS_SECRET_ACCESS_KEY']} AWS_ACCESS_KEY_ID=#{ENV['AWS_ACCESS_KEY_ID']} EC2_ROOT_SSH_KEY=\"#{File.basename EC2_ROOT_SSH_KEY}\" /mnt/create-hbase-image-remote\""
      puts "sh: #{sh}" if (options[:debug] == true)

      HCluster::ssh_to(image_creator_hostname,sh,
                       HCluster.image_output_handler(options[:debug]),
                       HCluster.image_output_handler(options[:debug]))

      # Register image
      image_location = "#{@ami_s3}/hbase-#{hbase_version}-#{options[:arch]}.manifest.xml"

      # FIXME: notify maintainers:
      # http://amazon-ec2.rubyforge.org/AWS/EC2/Base.html#register_image-instance_method does not
      # mention :name param (only :image_location).
      puts "registering image label: #{image_label} at manifest location: #{image_location}"
      begin
        registered_image = @@shared_base_object.register_image({
                                                                 :name => image_label,
                                                                 :image_location => image_location,
                                                                 :description => "HBase Cluster Image: HBase Version: #{hbase_version}; Hadoop Version: #{hadoop_version}"
                                                               })
      rescue AWS::InvalidManifest
        "Could not create image due to an 'AWS::InvalidManifest' error."
        if options[:debug] == true
          puts "Not terminating image creator instance: '#{@image_creator.dnsName}' in case you want to inspect it."
        else
          @@shared_base_object.terminate_instances({
                                                     :instance_id => @image_creator.instanceId
                                                   })
        end
        raise AWS::InvalidManifest
      end
      puts "create_image() finished - cleaning up.."
      if (!(options[:debug] == true))
        puts "shutting down image-builder #{@image_creator.instanceId}"
        @@shared_base_object.terminate_instances({
                                                   :instance_id => @image_creator.instanceId
                                                 })
      else
        puts "not shutting down image creator: '#{@image_creator.dnsName}' in case you want to inspect it."
      end
      registered_image.imageId
    end

    def Himage.find_owned_image(options)
      options = {
        :owner_id => @@owner_id
        }.merge(options)
      return Himage.describe_images(options,false)
    end

    def Himage.describe_images(options = {},search_all_visible_images = true)
      image_label = options[:label]
      options.delete(:label)

      if image_label
        if !(options[:all] == true)
          options = {
            :owner_id => @@owner_id
          }.merge(options)
        end

        retval = @@shared_base_object.describe_images(options)
        #filter by image_label
        if image_label

          retval2 = retval['imagesSet']['item'].collect{|image| 
            if (image.name == image_label)
              image
            end
          }.compact
        else
          retval2 = retval['imagesSet']['item'].detect{
            |image| image['image_id'] == options[:image_id]
          }
        end

        if ((retval2 == nil) && (search_all_visible_images == true))
          options.delete(:owner_id)
          puts "image named '#{image_label}' not found in owner #{@@owner_id}'s images; looking in all images (may take a while..)"
          retval = @@shared_base_object.describe_images(options)
          #filter by image_label
          retval2 = retval['imagesSet']['item'].detect{
            |image| image['name'] == image_label
          }
        end
        return retval2
      else
        @@shared_base_object.describe_images(options)
      end
    end

    def deregister
      Himage.deregister(self.image.imageId)
    end

    def Himage.deregister_image(image_id)
      Himage.deregister(image_id)
    end

    def Himage.deregister(image)
      @@shared_base_object.deregister_image({:image_id => image})
    end


  end
  
  #FIXME: move to yaml config file.
  EC2_ROOT_SSH_KEY = ENV['EC2_ROOT_SSH_KEY'] ? "#{ENV['EC2_ROOT_SSH_KEY']}" : "#{ENV['HOME']}/.ec2/root.pem"
  EC2_CERT = ENV['EC2_CERT'] ? "#{ENV['EC2_CERT']}" : "#{ENV['HOME']}/.ec2/cert.pem"
    
  puts "using #{EC2_ROOT_SSH_KEY} as ssh key."

  class HClusterStateError < StandardError
  end

  class HImageError < StandardError
  end
  
  class HClusterStartError < StandardError
  end
  
  class HCluster < AWS::EC2::Base

    def trim(string = "")
      string.gsub(/^\s+/,'').gsub(/\s+$/,'')
    end
    
    @@clusters = []
    # @@remote_init_script is used for post-bootup script for master and slaves; 
    # zookeeper has its own remote script: (hbase-ec2-init-zookeeper-remote.sh).
    @@remote_init_script = "hbase-ec2-init-remote.sh"
    
    # used for creating hbase images.
    @@default_base_ami_image = "ami-f61dfd9f"   # ec2-public-images/fedora-8-x86_64-base-v1.10.manifest.xml
    @@owner_id = ENV['AWS_ACCOUNT_ID'].gsub(/-/,'')
    
    def HCluster::owner_id
      @@owner_id
    end

    @@debug_level = 0
    
    # I feel like the describe_images method should be a class,
    # not, as in AWS::EC2::Base, an object method,
    # so I use this in HCluster::describe_images.
    # This is used to look up images, and is read-only, (except for a usage of AWS::EC2::Base::register_image below)
    # so hopefully, no race conditions are possible.
    begin
      @@shared_base_object = AWS::EC2::Base.new({
          :access_key_id => ENV['AWS_ACCESS_KEY_ID'],
          :secret_access_key=>ENV['AWS_SECRET_ACCESS_KEY'],
          :server => ENDPOINT
        })
    rescue
      puts "ooops..maybe you didn't define AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY? "
    end
    
    attr_reader :zks, :master, :secondary, :slaves, :aux, :zone, :zk_image_label, :master_image_label, :slave_image_label, :aux_image_label, :owner_id, :image_creator,:options,:hbase_version,:hbase_debug_level, :aws_connection
    
    def initialize_print_usage
      puts ""
      puts "HCluster.new"
      puts "  options: (default) (example)"
      puts "   :label (nil) (see Himage.my_images for a list of labels)"
      puts "   :ami (nil) (overrides :label - use only one of {:label,:ami}) ('ami-dc866db5')"
      puts "   :hbase_version (ENV['HBASE_VERSION'])"
      puts "   :num_regionservers  (3)"
      puts "   :num_zookeepers  (1)"
      puts "   :num_aux  (0)"
      puts "   :key_name (root)"
      puts "   :debug_level (@@debug_level)"
      puts "   :hbase_debug_level (INFO)"
      puts "   :validate_images  (true)"
      puts "   :security_group_prefix (hcluster)"
      puts ""
      puts "Himage.list shows a list of possible :label values."
    end

    def initialize( options = {} )

      if options.size == 0 || (options.ami == nil && options.label == nil)
        #not enough info to create cluster: show documentation.
        initialize_print_usage
        return nil
      end

      if options[:availability_zone]
        puts " ignoring :availability_zone - please pass to launch() instead."
        options.delete(:availability_zone)
      end

      options = {
        :label => nil,
        :hbase_version => ENV['HBASE_VERSION'],
        :num_regionservers => 3,
        :num_zookeepers => 1,
        :num_aux => 0,
        :arch => "x86_64",
        :key_name => "root",
        :debug_level => @@debug_level,
        :hbase_debug_level => 'DEBUG',
        :validate_images => true,
        :security_group_prefix => "hcluster",
      }.merge(options)

      @debug_level = options[:debug_level]

      @ami_owner_id = @@owner_id
      if options[:owner_id]
        @ami_owner_id = options[:owner_id]
      end

      #backwards compatibility
      #use :ami, not :image_id, in the future.
      if options[:image_id]
        options[:ami] = options[:image_id]
      end

      if options[:ami]
        #overrides options[:label] if present.
        puts "searching for AMI: '#{[options[:ami]]}'.."
        search_results = HCluster.search_images :ami => options[:ami], :output_fn => nil
        if search_results && search_results.size > 0
          if search_results[0].name
            puts "#{options.ami} has label: #{search_results[0].name}"
            options[:label] = search_results[0].name
          else
            puts "Warning: image name not found for AMI struct:\n#{search_results.to_yaml}."
            puts " (using 'No_label' as label)."  
            options[:label] = 'No_label'
          end
  
          options[:validate_images] = false

          @zk_ami = options[:ami]
          @master_ami = options[:ami]
          @slave_ami = options[:ami]
        else
          raise "AMI : '#{options[:ami]}' not found."
        end
      end
      
      # using same security group for all instances does not work now, so forcing to be separate.
      options[:separate_security_groups] = true

      if options[:label]
        options = {
          :zk_image_label => options[:label],
          :master_image_label => options[:label],
          :slave_image_label => options[:label]
        }.merge(options)
      else
        if options[:hbase_version]
          options = {
            :zk_image_label => "hbase-#{options[:hbase_version]}-#{options[:arch]}",
            :master_image_label => "hbase-#{options[:hbase_version]}-#{options[:arch]}",
            :slave_image_label => "hbase-#{options[:hbase_version]}-#{options[:arch]}",
          }.merge(options)
        else
          # User has no HBASE_VERSION defined, so check my images and use the first one.
          # If possible, would like to apply further filtering to find suitable images amongst 
          # them rather than just picking first.
          desc_images = HCluster.describe_images({:owner_id => @ami_owner_id})
          if desc_images
            desc_images = desc_images.imagesSet.item
            if desc_images[0] && desc_images[0].name
              puts "No HBASE_VERSION defined in your environment: using #{desc_images[0].name}."
              options = {
                :zk_image_label => desc_images[0].name,
                :master_image_label => desc_images[0].name,
                :slave_image_label => desc_images[0].name
              }.merge(options)
            else
              raise HClusterStartError,"No suitable HBase images found in your AMI list. Please create at least one with Himage.create_image()."
            end
          else
            raise HClusterStartError,"No suitable HBase images found in your AMI list. Please create at least one with Himage.create_image()."
          end
        end

      end
            
      # check env variables.
      raise HClusterStartError, 
      "AWS_ACCESS_KEY_ID is not defined in your environment." unless ENV['AWS_ACCESS_KEY_ID']
      
      raise HClusterStartError, 
      "AWS_SECRET_ACCESS_KEY is not defined in your environment." unless ENV['AWS_SECRET_ACCESS_KEY']
      
      raise HClusterStartError,
      "AWS_ACCOUNT_ID is not defined in your environment." unless ENV['AWS_ACCOUNT_ID']
      # remove dashes so that describe_images() can find images owned by this owner.
      @@owner_id = ENV['AWS_ACCOUNT_ID'].gsub(/-/,'')
      
      super(:access_key_id=>ENV['AWS_ACCESS_KEY_ID'],:secret_access_key=>ENV['AWS_SECRET_ACCESS_KEY'],:server => ENDPOINT)
      
      #for debugging
      @options = options
      @owner_id = @@owner_id
      
      #used to handle shared resources.
      @lock = Monitor.new
      
      @num_regionservers = options[:num_regionservers]
      @num_zookeepers = options[:num_zookeepers]
      @num_aux = options[:num_aux]
      @key_name = options[:key_name]
      @debug_level = options[:debug_level]
      @hbase_debug_level = options[:hbase_debug_level]

      @@clusters.push self
      
      @zks = []
      @master = nil
      @secondary = nil
      @slaves = []
      @aux = []
      @ssh_input = []
            
      @zk_image_label = options[:zk_image_label]
      @master_image_label = options[:master_image_label]
      @slave_image_label = options[:slave_image_label]
      
      if (options[:validate_images] == true)
        #validate image names (make sure they exist in Amazon's set).
        @zk_image_ = zk_image
        if (!@zk_image_)
          raise HClusterStartError,
          "could not find image called '#{@zk_image_label}'."
        end
        
        @master_image_ = master_image
        if (!@master_image_)
          raise HClusterStartError,
          "could not find image called '#{@master_image_label}'."
        end
        
        @slave_image_ = regionserver_image
        if (!@slave_image_)
          raise HClusterStartError,
          "could not find image called '#{@slave_image_label}'."
        end
        
      end
      
      #security_groups
      @security_group_prefix = options[:security_group_prefix]
      if (options[:separate_security_groups] == true)
        @zk_security_group = @security_group_prefix + "-zk"
        @rs_security_group = @security_group_prefix
        @master_security_group = @security_group_prefix + "-master"
        @secondary_security_group = @security_group_prefix + "-secondary"
        @aux_security_group = @security_group_prefix + "-aux"
      else
        @zk_security_group = @security_group_prefix
        @rs_security_group = @security_group_prefix
        @master_security_group = @security_group_prefix
        @aux_security_group = @security_group_prefix
      end
      
      #machine instance types
      if options[:zk_instance_type] != nil
        @zk_instance_type = options[:zk_instance_type]
      else
        @zk_instance_type = "m1.large"
      end
      if options[:rs_instance_type] != nil
        @rs_instance_type = options[:rs_instance_type]
      else
        @rs_instance_type = "m1.large"
      end
      if options[:aux_instance_type] != nil
        @aux_instance_type = options[:aux_instance_type]
      else
        @aux_instance_type = "m1.large"
      end
      if options[:master_instance_type] != nil
        @master_instance_type = options[:master_instance_type]
      else
        @master_instance_type = "m1.large"
      end
      @secondary_instance_type = @master_instance_type

      @state = "Initialized"
      
      sync
    end
    
    def dnsName
      master.dnsName
    end
    
    def ssh_input
      return @ssh_input
    end
    
    def status
      retval = {}
      retval['state'] = @state
      retval['num_zookeepers'] = @num_zookeepers
      retval['num_regionservers'] = @num_regionservers
      retval['num_aux'] = @num_aux
      retval['launchTime'] = @launchTime
      retval['dnsName'] = @dnsName
      if @master
        retval['master'] = @master.instanceId
      end
      retval
    end
    
    def state 
      return @state
    end
    
    def sync
      #instance method: update 'self' with all info related to EC2 instances
      # where security_group = @security_group_prefix
      
      i = 0
      zookeepers = 0
      @zks = []
      @slaves = []
      @aux = []

      if !describe_instances.reservationSet
        #no instances yet (even terminated ones have been cleaned up)
        return self.status
      end
      
      describe_instances.reservationSet.item.each do |ec2_instance_set|
        security_group = ec2_instance_set.groupSet.item[0].groupId
        if (security_group == @security_group_prefix)
          instances = ec2_instance_set.instancesSet.item
          instances.each {|inst|
            if (inst.instanceState.name != 'terminated')
              @slaves.push(inst)
            end
          }
        end
        if (security_group == (@security_group_prefix + "-zk"))
          instances = ec2_instance_set.instancesSet.item
          instances.each {|inst|
            if (inst['instanceState']['name'] != 'terminated')
              @zks.push(inst)
            end
          }
        end
        if (security_group == (@security_group_prefix + "-master"))
          if ec2_instance_set.instancesSet.item[0].instanceState.name != 'terminated'
            @master = ec2_instance_set.instancesSet.item[0]
            @state = @master.instanceState.name
            @dnsName = @master.dnsName
            @launchTime = @master.launchTime
          end
        end
        if (security_group == (@security_group_prefix + "-secondary"))
          if ec2_instance_set.instancesSet.item[0].instanceState.name != 'terminated'
            @secondary = ec2_instance_set.instancesSet.item[0]
          end
        end
        if (security_group == (@security_group_prefix + "-aux"))
          instances = ec2_instance_set.instancesSet.item
          instances.each {|inst|
            if (inst['instanceState']['name'] != 'terminated')
              @aux.push(inst)
            end
          }
        end
        i = i+1
      end

      if (@zks.size > 0)
        @num_zookeepers = @zks.size
      end
      
      if (@slaves.size > 0)
        @num_regionservers = @slaves.size
      end
      
      if (@aux.size > 0)
        @num_aux = @aux.size
      end
      
      self.status
      
    end
    
    def my_images
      HCluster.my_images
    end

    def HCluster.my_images
      HCluster.search_images owner_id => @@owner_id
      #Discard returned array - all we care about is the 
      # output that HCluster::search_images already printed.
      return nil
    end

    def HCluster.search_images_usage
      puts ""
      puts "HCluster.search_image(options)"
      puts "  options: (default value) (example)"
      puts "  :owner_id (nil)"
      puts "  :ami (nil) ('ami-dc866db5')"
      puts "  :output_fn (puts)"
    end

    def HCluster.search_images(options = nil)
      if options == nil || options.size == 0
        search_images_usage
        return nil
      end

      #FIXME: figure out fixed width/truncation for pretty printing tables.
      #if no ami, set owner_id to HCluster owner.
      if options[:ami]
        search_all_visible_images = true
      else
        if options[:label]
          search_all_visible_images = true
        else
          search_all_visible_images = false
          options = {
            :owner_id => @@owner_id,
          }.merge(options)
        end
      end

      options = {
        :output_fn => lambda{|line|
          puts line
        }
      }.merge(options)

      begin
        imgs = HCluster.describe_images(options).imagesSet.item
      rescue NoMethodError
        puts "image could not be found matching search criteria:\n#{pretty_print(options)}"
        return nil
      end
      if options[:output_fn]
        options.output_fn.call "label\t\t\t\tami\t\t\towner_id"
        options.output_fn.call "========================================================================="
        imgs.each {|image| 
          options.output_fn.call "#{image.name}\t\t#{image.imageId}\t\t#{image.imageOwnerId}"
        }
        options.output_fn.call ""
      end
      imgs
    end
    
    def HCluster.deregister_image(image)
      @@shared_base_object.deregister_image({:ami => image})
    end
    
    def HCluster.image_output_handler(debug)
      #includes code to get past Sun/Oracle's JDK License consent prompts.
      lambda{|line,channel|
        if (debug == true)
          puts line
        end
        if line =~ /Do you agree to the above license terms/
          channel.send_data "yes\n"
        end
        if line =~ /Press Enter to continue/
          channel.send_data "\n"
        end
      }
    end
    
    def HCluster.status
      if @@clusters.size > 0
        instances = @@clusters[@@clusters.first[0]].describe_instances
        status_do(instances)
      else 
        temp = HCluster.new("temp")
        retval = status_do(temp.describe_instances)
        @@clusters.delete("temp")
        retval
      end
    end

    def HCluster.[](name) 
      test = @@clusters[name]
      if test
        test
      else
        @@clusters[name] = HCluster.new(name)
      end
    end

    def HCluster::launch_usage
      puts ""
      puts "HCluster.launch usage"
      puts "  options: (description) (default, if any)"
      puts "   :hbase_debug_level ('INFO')"
      puts "   :availability_zone ('us-east-1c')"
      puts "   :key_name ('root')"
      puts ""
    end
    
    def launch(options = {})
      if options[:debug] == true
        options = {
          :stdout_handler => HCluster::echo_stdout,
          :stderr_handler => HCluster::echo_stderr
        }.merge(options)
      else
      end
      debug_level = @@debug_level
      debug_level = options[:debug_level] if options[:debug_level]

      @zone = options[:availability_zone]

      @state = "launching"

      if debug_level > 0
        puts("Checking security groups");
      end
      init_hbase_cluster_secgroups
      if debug_level > 0
        puts("Launching zookeepers");
      end
      launch_zookeepers(options)
      if debug_level > 0
        puts("Launching master");
      end
      launch_master(options)
      if debug_level > 0
        puts("Launching secondary");
      end
      launch_secondary(options)
      if debug_level > 0
        puts("Launching slaves");
      end
      launch_slaves(options)
      if (@num_aux > 0)
        if debug_level > 0
          puts ("Launching auxiliary instances");
        end
        launch_aux(options)
      end
      
      # if threaded, we would set to "pending" and then 
      # use join to determine when state should transition to "running".
      #    @launchTime = master.launchTime

      @state = "final initialization,,"
      #for portability, HCluster::run_test looks for /usr/local/hadoop/hadoop-test.jar.
      ssh("ln -s /usr/local/hadoop/hadoop-test-*.jar /usr/local/hadoop/hadoop-test.jar")

      if options[:kerberized] == true
        setup_kerberized_hbase
      end
      @state = "running"
    end
    
    def setup_kerberized_hbase
      ssh("cd /usr/local/hadoop-*; kinit -k -t conf/nn.keytab hadoop/#{master.privateDnsName.downcase}; bin/hadoop fs -mkdir /hbase; bin/hadoop fs -chown hbase /hbase")
      ssh("/usr/local/hbase-*/bin/hbase-daemon.sh start master")
      slaves.each {|inst|
        ssh_to(inst.dnsName, "/usr/local/hbase-*/bin/hbase-daemon.sh start regionserver")
      }
    end

    def init_hbase_cluster_secgroups
      # create security groups if necessary.
      groups = describe_security_groups
      found_master = false
      found_secondary = false
      found_rs = false
      found_zk = false
      found_aux = false
      
      groups['securityGroupInfo']['item'].each { |group| 
        if group['groupName'] =~ /^#{@security_group_prefix}$/
          found_rs = true
        end
        if group['groupName'] =~ /^#{@security_group_prefix}-master$/
          found_master = true
        end
        if group['groupName'] =~ /^#{@security_group_prefix}-secondary$/
          found_secondary = true
        end
        if group['groupName'] =~ /^#{@security_group_prefix}-zk$/
          found_zk = true
        end
        if group['groupName'] =~ /^#{@security_group_prefix}-aux$/
          found_aux = true
        end
      }

      created = false
      
      if (found_aux == false)
        puts "creating new security group: #{@security_group_prefix}-aux"
        create_security_group({
                                :group_name => "#{@security_group_prefix}-aux",
                                :group_description => "Group for HBase Auxiliaries."
                              })
        created = true
      end
      
      if (found_rs == false) 
        puts "creating new security group: #{@security_group_prefix}"
        create_security_group({
                                :group_name => "#{@security_group_prefix}",
                                :group_description => "Group for HBase Slaves."
                              })
        created = true
      end
      
      if (found_master == false) 
        puts "creating new security group: #{@security_group_prefix}-master"
        create_security_group({
                                :group_name => "#{@security_group_prefix}-master",
                                :group_description => "Group for HBase Master."
                              })
        created = true
      end
      
      if (found_secondary == false) 
        puts "creating new security group: #{@security_group_prefix}-secondary"
        create_security_group({
                                :group_name => "#{@security_group_prefix}-secondary",
                                :group_description => "Group for HBase Secondary."
                              })
        created = true
      end
      
      if (found_zk == false) 
        puts "creating new security group: #{@security_group_prefix}-zk"
        create_security_group({
                                :group_name => "#{@security_group_prefix}-zk",
                                :group_description => "Group for HBase Zookeeper quorum."
                              })
        created = true
      end

      if created == true
        groups2 = ["#{@security_group_prefix}", "#{@security_group_prefix}-master", "#{@security_group_prefix}-secondary", "#{@security_group_prefix}-zk", "#{@security_group_prefix}-aux"]
      
        # <allow ssh to each instance from anywhere.>
        groups2.each {|group|
          begin
            authorize_security_group_ingress(
                                           {
                                             :group_name => group,
                                             :from_port => 22,
                                             :to_port => 22,
                                             :cidr_ip => "0.0.0.0/0",
                                             :ip_protocol => "tcp"
                                           }
                                           )
          rescue AWS::InvalidPermissionDuplicate
            # authorization already exists - no problem.
          rescue NoMethodError
            # AWS::EC2::Base::HCluster internal error: fix AWS::EC2::Base
            puts "Sorry, AWS::EC2::Base internal error; please retry launch."
            return
          end
        
          #reciprocal full access for each security group.
          groups2.each {|other_group|
            begin
              authorize_security_group_ingress(
                                             {
                                               :group_name => group,
                                               :source_security_group_name => other_group
                                             }
                                             )
              sleep 1
            rescue AWS::InvalidPermissionDuplicate
              # authorization already exists - no problem.
            end
          }
        }
        sleep 1
      end
    end
    
    def HCluster.do_launch(options,name="",on_boot = nil)
      # @@shared_base_object requires :image_id instead of :ami; I prefer the latter.
      options[:image_id] = options[:ami] if options[:ami]

      instances = @@shared_base_object.run_instances(options)
      watch(name,instances)
      if on_boot
        on_boot.call(instances.instancesSet.item)
      end
      return instances.instancesSet.item
    end
    
    def HCluster.watch(name, instances, begin_output = "[launch:#{name}", end_output = "]\n")
      # note: this aws_connection is separate for this watch() function call:
      # this will hopefully allow us to run watch() in a separate thread if desired.
      #FIXME: cache this AWS::EC2::Base instance.
      @aws_connection = AWS::EC2::Base.new(:access_key_id=>ENV['AWS_ACCESS_KEY_ID'],:secret_access_key=>ENV['AWS_SECRET_ACCESS_KEY'],:server => ENDPOINT)
      
      print begin_output
      STDOUT.flush

      wait = true
      until wait == false
        wait = false
        if instances.instancesSet == nil
          raise "instances.instancesSet is nil."
        end
        if instances.instancesSet.item == nil
          raise "instances.instancesSet.item is nil."
        end
      instances.instancesSet.item.each_index {|i| 
          instance = instances.instancesSet.item[i]
          # get status of instance instance.instanceId.
          begin
            begin
              instance_info = @aws_connection.describe_instances({:instance_id => instance.instanceId}).reservationSet.item[0].instancesSet.item[0]
              status = instance_info.instanceState.name
            rescue OpenSSL::SSL::SSLError
              puts "aws_connection.describe_instance() encountered an SSL error - retrying."
              status = "waiting"
#rescue User::Hit::Control::C
# get info about instance so it's not ophaned/unterminatable.
            end

            if (!(status == "running"))
              wait = true
            else
              #instance is running 
              instances.instancesSet.item[i] = instance_info
            end
          rescue AWS::InvalidInstanceIDNotFound
            wait = true
            puts " watch(#{name}): instance '#{instance.instanceId}' not found (might be transitory problem; retrying.)"
          end
        }
        if wait == true
          putc "."
          sleep 1
        end
      end
      
      print end_output
      STDOUT.flush
      
    end
    
    def launch_zookeepers(options = {})
      options = {
        :stdout_handler => HCluster::summarize_stdout,
        :stderr_handler => HCluster::summarize_stderr
      }.merge(options)

      options[:ami] = zk_image['imageId']
      options[:min_count] = @num_zookeepers
      options[:max_count] = @num_zookeepers
      options[:security_group] = @zk_security_group
      options[:instance_type] = @zk_instance_type
      options[:availability_zone] = @zone
      options[:key_name] = @key_name
      @zks = HCluster.do_launch(options,"zk",lambda{|instances|setup_zookeepers(instances,
                                                                          options[:stdout_handler],
                                                                          options[:stderr_handler])})
    end
        
    def launch_master(options = {})
      options = {
        :stdout_handler => HCluster::summarize_stdout,
        :stderr_handler => HCluster::summarize_stderr,
        :extra_packages => ""
      }.merge(options)

      options[:ami] = master_image['imageId'] 
      options[:min_count] = 1
      options[:max_count] = 1
      options[:security_group] = @master_security_group
      options[:instance_type] = @master_instance_type
      options[:availability_zone] = @zone
      options[:key_name] = @key_name

      @master = HCluster.do_launch(options,"master",lambda{|instances| setup_master(instances[0], options[:stdout_handler],options[:stderr_handler], options[:extra_packages])})[0]
    end
    
    def launch_secondary(options = {})
      options = {
        :stdout_handler => HCluster::summarize_stdout,
        :stderr_handler => HCluster::summarize_stderr,
        :extra_packages => ""
      }.merge(options)

      options[:ami] = master_image['imageId'] 
      options[:min_count] = 1
      options[:max_count] = 1
      options[:security_group] = @secondary_security_group
      options[:instance_type] = @secondary_instance_type
      options[:availability_zone] = @zone
      options[:key_name] = @key_name

      @secondary = HCluster.do_launch(options,"secondary",lambda{|instances| setup_secondary(instances[0], options[:stdout_handler],options[:stderr_handler], options[:extra_packages])})[0]
    end
    
    def launch_slaves(options = {})
      options = {
        :stdout_handler => HCluster::summarize_stdout,
        :stderr_handler => HCluster::summarize_stderr,
        :extra_packages => ""
      }.merge(options)

      options[:ami] = regionserver_image['imageId']
      options[:min_count] = @num_regionservers
      options[:max_count] = @num_regionservers
      options[:security_group] = @rs_security_group
      options[:instance_type] = @rs_instance_type
      options[:availability_zone] = @zone
      options[:key_name] = @key_name
      @slaves = HCluster.do_launch(options,"rs",lambda{|instances|setup_slaves(instances,
                                                                               options[:stdout_handler],
                                                                               options[:stderr_handler],
                                                                               options[:extra_packages])})
    end
    
    def launch_aux(options = {})
      options = {
        :stdout_handler => HCluster::summarize_stdout,
        :stderr_handler => HCluster::summarize_stderr,
        :extra_packages => ''
      }.merge(options)

      options[:ami] = regionserver_image['imageId']
      options[:min_count] = @num_aux
      options[:max_count] = @num_aux
      options[:security_group] = @aux_security_group
      options[:instance_type] = @aux_instance_type
      options[:availability_zone] = @zone
      options[:key_name] = @key_name
      @aux = HCluster.do_launch(options,"aux",lambda{|instances|setup_aux(instances,
                                                                               options[:stdout_handler],
                                                                               options[:stderr_handler],
                                                                               options[:extra_packages])})
    end
    
    # note that default 'zks' argument is cluster's current set of zookeepers.
    # so calling e.g. "mycluster.setupzookeepers" with no arguments will cause
    # the zookeeper setup to re-run. The effect on any existing zookeeper processes
    # depends on the specific behavior of hbase-ec2-init-zookeeper-remote.sh.
    def setup_zookeepers(zks = @zks, stdout_handler = HCluster::summarize_output, stderr_handler = HCluster::summarize_output)
      #when zookeepers are ready, copy info over to them..
      #for each zookeeper, copy ~/hbase-ec2/bin/hbase-ec2-init-zookeeper-remote.sh to zookeeper, and run it.
      HCluster::until_ssh_able(zks, @debug_level)

      @zookeeper_quorum = zks.collect{ |zk| zk.privateDnsName }.join(',')
      if @debug_level > 0
        puts "zk quorum: #{@zookeeper_quorum}"
      end

      zks.each { |zk|
        # if no zone specified by user, use the zone that AWS chose for the first
        # instance launched in the cluster (the first zookeeper).
        @zone = zk.placement['availabilityZone'] if !@zone
        if @debug_level > 0
          puts "zk dnsname: #{zk.dnsName}"
        end
        ready = false
        until ready
          begin
            HCluster::scp_to(zk.dnsName,File.dirname(__FILE__) +"/../bin/hbase-ec2-init-zookeeper-remote.sh","/var/tmp")
            HCluster::ssh_to(zk.dnsName,
                         "sh -c \"ZOOKEEPER_QUORUM=\\\"#{@zookeeper_quorum}\\\" sh /var/tmp/hbase-ec2-init-zookeeper-remote.sh\"",
                         stdout_handler,stderr_handler,
                         "[setup:zk:#{zk.dnsName}",
                         "]\n")
            ready = true
          rescue
          end
        end
      }
    end

    def setup_master(master = @master, stdout_handler = HCluster::summarize_output, stderr_handler = HCluster::summarize_output, extra_packages = "")
      #set cluster's dnsName to that of master.
      @dnsName = master.dnsName
      @master = master
      
      HCluster::until_ssh_able([master], @debug_level)

      ready = false
      until ready
        begin
          HCluster::scp_to(master.dnsName,"#{EC2_ROOT_SSH_KEY}","/root/.ssh/id_rsa")
          HCluster::ssh_to(master.dnsName,"chmod 600 /root/.ssh/id_rsa",HCluster::consume_output,HCluster::consume_output,nil,nil)
          init_script = File.dirname(__FILE__) +"/../bin/#{@@remote_init_script}"
          HCluster::scp_to(master.dnsName,init_script,"/root/#{@@remote_init_script}")
          HCluster::ssh_to(master.dnsName,"chmod 700 /root/#{@@remote_init_script}",HCluster::consume_output,HCluster::consume_output,nil,nil)
          if @debug_level > 0
            puts "sh /root/#{@@remote_init_script} #{master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\""
          end
          HCluster::ssh_to(master.dnsName,"sh /root/#{@@remote_init_script} #{master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\"", stdout_handler,stderr_handler, "[setup:master:#{master.dnsName}","]\n")
          ready = true
        rescue
        end
      end

      @master.state = "running"
    end
    
    def setup_secondary(secondary = @secondary, stdout_handler = HCluster::summarize_output, stderr_handler = HCluster::summarize_output, extra_packages = "")
      init_script = File.dirname(__FILE__) +"/../bin/#{@@remote_init_script}"
      HCluster::until_ssh_able([secondary], @debug_level)
      ready = false
      until ready
        begin
          HCluster::scp_to(secondary.dnsName,"#{EC2_ROOT_SSH_KEY}","/root/.ssh/id_rsa")
          HCluster::ssh_to(secondary.dnsName,"chmod 600 /root/.ssh/id_rsa",HCluster::consume_output,HCluster::consume_output,nil,nil)
          HCluster::scp_to(secondary.dnsName,init_script,"/root/#{@@remote_init_script}")
          HCluster::ssh_to(secondary.dnsName,"chmod 700 /root/#{@@remote_init_script}",HCluster::consume_output,HCluster::consume_output,nil,nil)
          puts "sh /root/#{@@remote_init_script} #{@master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\""
          HCluster::ssh_to(secondary.dnsName,"sh /root/#{@@remote_init_script} #{@master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\"", stdout_handler,stderr_handler, "[setup:secondary:#{secondary.dnsName}","]\n")
          ready = true
        rescue
        end
      end
    end
    
    def setup_slaves(slaves = @slaves, stdout_handler = HCluster::summarize_output, stderr_handler = HCluster::summarize_output, extra_packages = "")
      init_script = File.dirname(__FILE__) +"/../bin/#{@@remote_init_script}"
      HCluster::until_ssh_able(slaves, @debug_level)
      slaves.each {|inst|
        ready = false
        until ready
          begin
            HCluster::scp_to(inst.dnsName,"#{EC2_ROOT_SSH_KEY}","/root/.ssh/id_rsa")
            HCluster::ssh_to(inst.dnsName,"chmod 600 /root/.ssh/id_rsa",HCluster::consume_output,HCluster::consume_output,nil,nil)
            HCluster::scp_to(inst.dnsName,init_script,"/root/#{@@remote_init_script}")
            HCluster::ssh_to(inst.dnsName,"chmod 700 /root/#{@@remote_init_script}",HCluster::consume_output,HCluster::consume_output,nil,nil)
            puts "sh /root/#{@@remote_init_script} #{@master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\""
            HCluster::ssh_to(inst.dnsName,"sh /root/#{@@remote_init_script} #{@master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\"", stdout_handler,stderr_handler, "[setup:rs:#{inst.dnsName}","]\n")
            ready = true
          rescue
          end
        end
      }
    end

    def setup_aux(aux = @aux, stdout_handler = HCluster::summarize_output, stderr_handler = HCluster::summarize_output, extra_packages = "")
      init_script = File.dirname(__FILE__) +"/../bin/#{@@remote_init_script}"
      HCluster::until_ssh_able(aux, @debug_level)
      aux.each {|inst|
        ready = false
        until ready
          begin
            HCluster::scp_to(inst.dnsName,"#{EC2_ROOT_SSH_KEY}","/root/.ssh/id_rsa")
            HCluster::ssh_to(inst.dnsName,"chmod 600 /root/.ssh/id_rsa",HCluster::consume_output,HCluster::consume_output,nil,nil)
            HCluster::scp_to(inst.dnsName,init_script,"/root/#{@@remote_init_script}")
            HCluster::ssh_to(inst.dnsName,"chmod 700 /root/#{@@remote_init_script}",HCluster::consume_output,HCluster::consume_output,nil,nil)
            if @debug_level > 0
              puts "sh /root/#{@@remote_init_script} #{@master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\""
            end
            HCluster::ssh_to(inst.dnsName,"sh /root/#{@@remote_init_script} #{@master.dnsName} \"#{@zookeeper_quorum}\" #{@num_regionservers} \"#{extra_packages}\" \"#{@hbase_debug_level}\"", stdout_handler,stderr_handler, "[setup:aux:#{inst.dnsName}","]\n")
            ready = true
          rescue
          end
        end
      }
    end
    
    def terminate_zookeepers
      @zks.each { |zk|
        options = {}
        if zk.instanceId
          options[:instance_id] = zk.instanceId
          puts "terminating zookeeper: #{zk.instanceId}"
          terminate_instances(options)
        end
      }
      @zks = []
    end
    
    def terminate_master
      if @master && @master.instanceId
        options = {}
        options[:instance_id] = @master.instanceId
        puts "terminating master: #{@master.instanceId}"
        terminate_instances(options)
      end
      @master = nil
      if @secondary && @secondary.instanceId
        options = {}
        options[:instance_id] = @secondary.instanceId
        puts "terminating secondary: #{@secondary.instanceId}"
        terminate_instances(options)
      end
      @secondary = nil
    end
    
    def terminate_slaves
      @slaves.each { |inst|
        if inst.instanceId
          options = {}
          options[:instance_id] = inst.instanceId
          puts "terminating regionserver: #{inst.instanceId}"
          terminate_instances(options)
        end
      }
      @slaves = []
    end
    
    def terminate_aux
      @aux.each { |inst|
        if inst.instanceId
          options = {}
          options[:instance_id] = inst.instanceId
          puts "terminating regionserver: #{inst.instanceId}"
          terminate_instances(options)
        end
      }
      @aux = []
    end
    
    def describe_instances(options = {})
      #   "If no instance IDs are provided, information of all relevant instances
      # information will be returned. If an instance is specified that does not exist a fault is returned. 
      # If an instance is specified that exists but is not owned by the user making the request, 
      # then that instance will not be included in the returned results.

      #   "Recently terminated instances will be included in the returned results 
      # for a small interval subsequent to their termination. This interval is typically 
      # of the order of one hour."
      #  - http://amazon-ec2.rubyforge.org/AWS/EC2/Base.html#describe_instances-instance_method
      retval = nil
      #FIXME: a mutex doesn't seem to be needed: isn't AWS::EC2::Base::describe_instances read-only?
      @lock.synchronize {
        retval = super(options)
      }
      retval
    end
    
    #overrides parent: tries to find image using owner_id, which will be faster to iterate through (in .detect loop)
    # if not found, tries all images.
    def HCluster.describe_images(options,image_label = nil,search_all_visible_images = true)

      # @@shared_base_object requires :image_id instead of :ami; I prefer the latter.
      options[:image_id] = options[:ami] if options[:ami]

      if image_label
        options = {
          :owner_id => @@owner_id
        }.merge(options)
        
        retval = @@shared_base_object.describe_images(options)
        #filter by image_label
        retval2 = retval['imagesSet']['item'].detect{
          |image| image['name'] == image_label
        }
        
        if (retval2 == nil and search_all_visible_images == true)
          old_owner = options[:owner_id]
          options.delete(:owner_id)
          puts "image '#{image_label}' not found in owner #{old_owner}'s images; looking in all images (may take a while..)"
          retval = @@shared_base_object.describe_images(options)
          #filter by image_label
          retval2 = retval['imagesSet']['item'].detect{
            |image| image['name'] == image_label
          }
        end
        retval2
      else
        @@shared_base_object.describe_images(options)
      end
    end

    def zk_image
      if @zk_ami
        return @@shared_base_object.describe_images(:image_id => @zk_ami)['imagesSet']['item'][0]
      end
      get_image(@zk_image_label)
    end
    
    def regionserver_image
      if @slave_ami
        return @@shared_base_object.describe_images(:image_id => @slave_ami)['imagesSet']['item'][0]
      end
      get_image(@slave_image_label)
    end
    
    def master_image
      if @master_ami
        return @@shared_base_object.describe_images(:image_id => @master_ami)['imagesSet']['item'][0]
      end
      get_image(@master_image_label)
    end
    
    def HCluster.find_owned_image(image_label)
      return describe_images({:owner_id => @@owner_id},image_label,false)
    end
    
    def get_image(image_label,options = {})
      options = {
        :owner_id => @ami_owner_id
      }.merge(options)

      matching_image = HCluster.describe_images(options,image_label)
      if matching_image
        matching_image
      else
        raise HClusterStartError,
        "describe_images({:owner_id => '#{@ami_owner_id}'},'#{image_label}'): couldn't find #{image_label}, even in all of Amazon's viewable images."
      end
    end
    
    def if_null_image(retval,image_label)
      if !retval
        raise HClusterStartError, 
        "Could not find image '#{image_label}' in instances viewable by AWS Account ID: '#{@@owner_id}'."
      end
    end
    
    def run_test(test,stdout_line_reader = lambda{|line,channel| puts line},stderr_line_reader = lambda{|line,channel| puts "(stderr): #{line}"})
      #fixme : fix hardwired version (first) then path to hadoop (later)
      ssh("/usr/local/hadoop/bin/hadoop jar /usr/local/hadoop/hadoop-test.jar #{test}",
          stdout_line_reader,
          stderr_line_reader)
    end
    
    #If command == nil, open interactive channel.
    def HCluster.ssh_to(host,command = nil,
                        stdout_line_reader = lambda{|line,channel| puts line},
                        stderr_line_reader = lambda{|line,channel| puts "(stderr): #{line}"},
                        begin_output = nil,
                        end_output = nil)
      # variant of ssh with different param ordering.
      ssh_with_host(command,stdout_line_reader,stderr_line_reader,host,begin_output,end_output)
    end
    
    def HCluster.ssh_with_host(command,stdout_line_reader,stderr_line_reader,host,begin_output,end_output)
      if command == nil
        interactive = true
      end
      
      if begin_output
        print begin_output
        STDOUT.flush
      end
      # http://net-ssh.rubyforge.org/ssh/v2/api/classes/Net/SSH.html#M000013
      # paranoid=>false because we should ignore known_hosts, since AWS IPs get frequently recycled
      # and their servers' private keys will vary.
      
      until command == "exit\n"
        if interactive == true
          print "#{host} $ "
          command = gets
        end
        Net::SSH.start(host,'root',
                             :keys => [EC2_ROOT_SSH_KEY],
                             :paranoid => false
                             ) do |ssh|
          stdout = ""
          channel = ssh.open_channel do |ch|
            channel.exec(command) do |ch, success|
              #FIXME: throw exception(?)
              puts "channel.exec('#{command}') was not successful." unless success
            end
            channel.on_data do |ch, data|
              stdout_line_reader.call(data,channel)
              # example of how to talk back to server.
              #          channel.send_data "something for stdin\n"
            end
            channel.on_extended_data do |channel, type, data|
              stderr_line_reader.call(data,channel)
            end
            channel.wait
            if !(interactive == true)
              #Cause exit from until(..) loop.
              command = "exit\n"
            end
            channel.on_close do |channel|
              # cleanup, if any..
            end
          end
        end
      end
      if end_output
        print end_output
        STDOUT.flush
      end
    end
    
    # Send a command and handle stdout and stderr 
    # with supplied anonymous functions (puts by default)
    # to a specific host (master by default).
    # If command == nil, open interactive channel.
    def ssh(command = nil,
            stdout_line_reader = HCluster.echo_stdout,
            stderr_line_reader = HCluster.echo_stderr,
            host = self.master.dnsName,
            begin_output = nil,
            end_output = nil)
      if (host == @dnsName)
        raise HClusterStateError,
        "This HCluster has no master hostname. Cluster summary:\n#{self.to_s}\n" if (host == nil)
      end
      HCluster.ssh_with_host(command,stdout_line_reader,stderr_line_reader,host,begin_output,end_output)
    end

    def ssh_to(host,
               command=nil,
               stdout_line_reader = HCluster.echo_stdout,
               stderr_line_reader = HCluster.echo_stderr,
               begin_output = nil,
               end_output = nil)
      HCluster.ssh_with_host(command,stdout_line_reader,stderr_line_reader,host,begin_output,end_output)
    end

    #Matches unix "scp" argument conventions:
    #e.g. "cluster.scp("/path/to/localfile","host:/path_to_remote_path"),
    #Except that unix "scp" will not supply a default host, but we  will use cluster.dnsName
    #as the default host.
    #FIXME: implement (-r)ecursive support.
    def scp(local_path,remote_path = "#{dnsName}:")
      if  /([^:]+):(.*)/.match(remote_path)
        host                     = /([^:]+):(.*)/.match(remote_path)[1]
        remote_path_without_host = /([^:]+):(.*)/.match(remote_path)[2]
      else
        host = dnsName
        remote_path_without_host = remote_path
      end
      HCluster.scp_to(host,local_path,remote_path_without_host)
    end

    def scp_to(host,local_path,remote_path)
      HCluster::scp_to(host,local_path,remote_path)
    end

    def HCluster.scp_to(host,local_path,remote_path)
      #http://net-ssh.rubyforge.org/scp/v1/api/classes/Net/SCP.html#M000005
      # paranoid=>false because we should ignore known_hosts, since AWS IPs get frequently recycled
      # and their servers' private keys will vary.
      done = false
      unless done
        begin
          Net::SCP.start(host,'root',
                         :keys => [EC2_ROOT_SSH_KEY],
                         :paranoid => false
                         ) do |scp|
              scp.upload! local_path,remote_path
            end
          done = true
        rescue
        end
      end
    end
    
    def terminate
      terminate_zookeepers
      terminate_master
      terminate_slaves
      terminate_aux
      @state = "terminated"
      status
    end

    def HCluster::terminate
      # Note: this terminates all instances but does not sync()
      # any individual HCluster objects, so clusters will have
      # old information about now-terminated instances.
      # FIXME: add prompt.
      puts "Terminating ALL instances owned by you (owner_id=#{@@owner_id})."

      @aws_connection or (@aws_connection = AWS::EC2::Base.new(:access_key_id=>ENV['AWS_ACCESS_KEY_ID'],:secret_access_key=>ENV['AWS_SECRET_ACCESS_KEY'],:server => ENDPOINT))
      @aws_connection or raise HClusterStateError,"Could not log you in to AWS: check AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in your environment."

      @aws_connection.describe_instances.reservationSet.item.each do |ec2_instance_set|
        ec2_instance_set.instancesSet.item.each {|instance|
          puts "terminating instance: #{instance.instanceId} (#{instance.imageId})"
          @@shared_base_object.terminate_instances :instance_id => instance.instanceId
        }
      end
    end
    
    def to_s
      if (@state)
        retval = "HCluster (state='#{@state}'): #{@num_regionservers} regionserver#{((@numregionservers == 1) && '') || 's'}; #{@num_zookeepers} zookeeper#{((@num_zookeepers == 1) && '') || 's'}; #{@num_aux} aux#{((@num_aux == 1) && '') || 's'}; hbase_version:#{options[:hbase_version]};"
        if (@aux)
          retval = retval + "; 1 aux"
        end
        retval = retval + "."
      end
    end

    private
    def HCluster.status_do(instances)
      retval = []
      instances.reservationSet['item'].each do |ec2_instance_set|
        security_group = ec2_instance_set.groupSet['item'][0]['groupId']
        if (security_group =~ /-zk$/)
        else
          if (security_group =~ /-master$/) 
          else
            registered_cluster = @@clusters[security_group]
            if !registered_cluster
              registered_cluster = HCluster.new(security_group)
            end
            registered_cluster.sync
            retval.push(registered_cluster.status)
          end
        end
      end
      return retval
    end
    
    def HCluster.until_ssh_able(instances, debug_level=@@debug_level)
      # do not return until every instance in the instances array is ssh-able.
      # FIXME: make multithreaded: test M (M > 0) instances in M threads until all instances are tested.
      instances.each {|instance|
        connected = false
        until connected == true
          begin
            if debug_level > 0
              puts "#{instance.dnsName} trying to ssh.."
            end
            ssh_to(instance.dnsName,"true",HCluster::consume_output,HCluster::consume_output,nil,nil)
            if debug_level > 0
              puts "#{instance.dnsName} is sshable."
            end
            connected = true
          rescue Net::SSH::AuthenticationFailed
            if debug_level > 0
              puts "host: #{instance.dnsName} not ready yet - waiting.."
            end
            sleep 5
          rescue Errno::ECONNREFUSED
            if debug_level > 0
              puts "host: #{instance.dnsName} not ready yet (connection refused) - waiting.."
            end
            sleep 5
          rescue Errno::ECONNRESET
            if debug_level > 0
              puts "host: #{instance.dnsName} not ready yet (connection reset) - waiting.."
            end
            sleep 5
          rescue Errno::ETIMEDOUT
            if debug_level > 0
              puts "host: #{instance.dnsName} not ready yet (timed out) - waiting.."
            end
            sleep 5
          rescue OpenSSL::SSL::SSLError
            if debug_level > 0
              puts "host: #{instance.dnsName} not ready yet (ssl error) - waiting.."
            end
            sleep 5
          end
        end
      }
    end
    
    def HCluster.echo_stdout
      return lambda{|line,channel|
        puts line
      }
    end
    
    def HCluster.echo_stderr 
      return lambda{|line,channel|
        puts "(stderr): #{line}"
      }
    end
    
    def HCluster.consume_output 
      #don't print anything for each line.
      return lambda{|line|
      }
    end
    
    def HCluster.summarize_stdout
      HCluster.summarize_output
    end

    def HCluster.summarize_stderr
      HCluster.summarize_output
    end

    def HCluster.summarize_output
      #output one '.' per line.
      return lambda{|line,channel|
        putc "."
      }
    end
    
    def HCluster.major_version(version_string)
      begin
        /(hbase-)?([0-9+])/.match(version_string)[2].to_i
      rescue NoMethodError
        "no minor version found for version #{version_string}."
      end
    end
    
    def HCluster.minor_version(version_string)
      begin
        /(hbase-)?[0-9+].([0-9]+)/.match(version_string)[2].to_i
      rescue NoMethodError
        "no minor version found for version '#{version_string}'."
      end
    end

    def HCluster.label_to_hbase_version(label)
      begin
        /(hbase|hadoop)-([\w\.\-]+?)(-SNAPSHOT)?(x86_64|i386|\.tar\.gz)/.match(label)[2]
      rescue NoMethodError
        "could not convert label: '#{label}' to an hbase version."
      end
    end
  end

end
