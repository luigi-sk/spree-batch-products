class ProductDatasheetAdvanced < ProductDatasheet
  require 'pp'
  require 'open-uri'
  
  def handle_before_import
    @products_before_import = Product.all
    @names_of_products_before_import = []
    @products_before_import.each do |product|
      @names_of_products_before_import << product.name
    end
    log("#{@names_of_products_before_import}")
  end

  def perform
    handle_before_import

    workbook =
    begin
      Spreadsheet.open self.xls.to_file
    rescue
      puts 'Failed to open xls attachment for processing'
      return false
    end
    worksheet = workbook.worksheet(0)
    columns = [worksheet.dimensions[2], worksheet.dimensions[3]]
    header_row = worksheet.row(0)

    headers = []

    col={}
    idx=columns[0]
    header_row.each do |key|
      headers << key
#      if Product.column_names.include?(key) or Variant.column_names.include?(key)
#        headers << key
#      else
#        headers << nil
#      end
      col[key]=idx
      idx+=1
    end

    worksheet.each(1) do |row|
      attr_hash = {}
      for i in columns[0]..columns[1]
        attr_hash[headers[i]] = row[i].to_s if row[i] and headers[i] # if there is a value and a key; .to_s is important for ARel
      end

      product_information = attr_hash

      #Manually set available_on if it is not already set
      product_information[:available_on] = DateTime.now - 1.day if product_information[:available_on].nil?


      #Trim whitespace off the beginning and end of row fields
      row.each do |r|
        next unless r.is_a?(String)
        r.gsub!(/\A\s*/, '').chomp!
      end

      if IMPORT_PRODUCT_SETTINGS[:create_variants]
        field = IMPORT_PRODUCT_SETTINGS[:variant_comparator_field].to_s
        unless p = Product.find(:first, :conditions => ["#{field} = ?",attr_hash[field]])
          log("create product #{product_information[:sku]}(#{product_information[:name]})")
          create_product_res = create_product_using(product_information)
          p = Product.find(:first, :conditions => ["#{field} = ?", attr_hash[field]])
          @records_updated+=1
        end
        unless p.nil?
          log("update product #{product_information[:sku]}(#{product_information[:name]})")
          p.update_attribute(:deleted_at, nil) if p.deleted_at #Un-delete product if it is there
          p.variants.each { |variant| variant.update_attribute(:deleted_at, nil) }
          create_variant_for(p, :with => product_information)
          @records_matched+=1
          @records_updated+=1
        end
        next unless create_product_res
      else
        next unless create_product_using(product_information)
        @records_updated+=1
      end
    end

    if IMPORT_PRODUCT_SETTINGS[:destroy_original_products]
      @products_before_import.each { |p| p.destroy }
    end

    log("Importing products for #{self.xls_file_name} completed at #{DateTime.now}")
    self.update_attribute(:processed_at, Time.now)
    #rescue Exception => exp
    #  log("An error occurred during import, please check file and try again. (#{exp.message})\n#{exp.backtrace.join('\n')}", :error)
    #  raise Exception(exp.message)
    #end
  end

  # create_variant_for
  # This method assumes that some form of checking has already been done to
  # make sure that we do actually want to create a variant.
  # It performs a similar task to a product, but it also must pick up on
  # size/color options
  def create_variant_for(product, options = {:with => {}})
    return if options[:with].nil?

    variant = product.variants.new
    variant_changed = false

    #Remap the options - oddly enough, Spree's product model has master_price and cost_price, while
    #variant has price and cost_price.
    options[:with][:price] = options[:with].delete(:master_price)

    #First, set the primitive fields on the object (prices, etc.)
    unless options[:with][IMPORT_PRODUCT_SETTINGS[:options_field]].nil?
      variants = [nil]
      variants[0] = options[:with][IMPORT_PRODUCT_SETTINGS[:options_field]].split("=")
      variants[0] = [] if variants[0].size == 0

      variants.each do |field_a|
        continue if field_a.size == 0
        field = field_a[0]
        value = field_a[1]
        variant.send("#{field}=", value) if variant.respond_to?("#{field}=")
        applicable_option_type = OptionType.find(:first, :conditions => [
          "lower(presentation) = ? OR lower(name) = ?",
          field.to_s, field.to_s]
        )
        if applicable_option_type.nil?
          applicable_option_type = OptionType.new({
              :name => field.to_s,
              :presentation => field.to_s
          })
          applicable_option_type.save
        end
        if applicable_option_type.is_a?(OptionType)
          product.option_types << applicable_option_type unless product.option_types.include?(applicable_option_type)
          option_type_value = applicable_option_type.option_values.find(
            :all,
            :conditions => ["presentation = ? OR name = ?", value, value]
          )
          unless option_type_value.any?
            option_type_value = applicable_option_type.option_values.new({
              :presentation => value,
              :name => value
            })
            option_type_value.save
          end
          unless has_option_values?(product, field, value)
            variant.option_values << option_type_value
            variant_changed = true
          end
        end
      end
    end

    if variant.valid? and variant_changed
      variant.save

      #Associate our new variant with any new taxonomies
      IMPORT_PRODUCT_SETTINGS[:taxonomy_fields].each do |field|
        associate_product_with_taxon(variant.product, field.to_s, options[:with][field])
      end

      #Finally, attach any images that have been specified
      IMPORT_PRODUCT_SETTINGS[:image_fields].each do |field|
        find_and_attach_image_to(variant, options[:with][field])
      end

      #Log a success message
      log("Variant of SKU #{variant.sku} successfully imported.\n")
    elsif !variant_changed
      option_values = []
      variants_to_delete = []
      product.variants.each do |variant|
        if option_values.include?(variant.option_values)
          variants_to_delete << variant
        else
          option_values << variant.option_values
        end
      end
      variants_to_delete.each do |variant|
        variant.destroy
      end

    else
      log("A variant could not be imported - here is the information we have:\n" +
          "#{pp options[:with]}, :error")
      return false
    end
  end

  def has_option_values?(product, key, value)
    product.variants.each do |variant|
      option_values = variant.option_values.find(:all,
          :conditions => ["name = ? OR presentation = ?", value, value])
      option_values.each do |option_value|
        if option_value.option_type.name == key or
          option_value.option_type.presentation == key
            return true
        end
      end

    end

    false
  end


  # create_product_using
  # This method performs the meaty bit of the import - taking the parameters for the
  # product we have gathered, and creating the product and related objects.
  # It also logs throughout the method to try and give some indication of process.
  def create_product_using(params_hash)
    product = Product.new

    #The product is inclined to complain if we just dump all params
    # into the product (including images and taxonomies).
    # What this does is only assigns values to products if the product accepts that field.
    params_hash.each do |field, value|
      value = value.force_encoding("UTF-8") if value.instance_of? String
      product.send("#{field}=", value) if product.respond_to?("#{field}=")
    end

    after_product_built(product, params_hash)

    #We can't continue without a valid product here
    unless product.valid?
      log("A product could not be imported - here is the information we have:\n" +
          "#{pp params_hash}, :error")
      return false
    end

    #Just log which product we're processing
    log(product.name)

    #This should be caught by code in the main import code that checks whether to create
    #variants or not. Since that check can be turned off, however, we should double check.
    if @names_of_products_before_import.include? product.name
      log("#{product.name} is already in the system.\n")
    else
      #Save the object before creating asssociated objects
      product.save


      #Associate our new product with any taxonomies that we need to worry about
      IMPORT_PRODUCT_SETTINGS[:taxonomy_fields].each do |field|
        associate_product_with_taxon(product, field.to_s, params_hash[field.to_sym])
      end

      #Finally, attach any images that have been specified
      IMPORT_PRODUCT_SETTINGS[:image_fields].each do |field|
        find_and_attach_image_to(product, params_hash[field.to_sym])
      end

      if IMPORT_PRODUCT_SETTINGS[:multi_domain_importing] && product.respond_to?(:stores)
        begin
          store = Store.find(
            :first,
            :conditions => ["id = ? OR code = ?",
              params_hash[IMPORT_PRODUCT_SETTINGS[:store_field]],
              params_hash[IMPORT_PRODUCT_SETTINGS[:store_field]]
            ]
          )

          product.stores << store
        rescue
          log("#{product.name} could not be associated with a store. Ensure that Spree's multi_domain extension is installed and that fields are mapped to the CSV correctly.")
        end
      end

      #Log a success message
      log("#{product.name} successfully imported.\n")
    end
    return true
  end

  # get_column_mappings
  # This method attempts to automatically map headings in the CSV files
  # with fields in the product and variant models.
  # If the headings of columns are going to be called something other than this,
  # or if the files will not have headings, then the manual initializer
  # mapping of columns must be used.
  # Row is an array of headings for columns - SKU, Master Price, etc.)
  # @return a hash of symbol heading => column index pairs
  def get_column_mappings(row)
    mappings = {}
    row.each_with_index do |heading, index|
      mappings[heading.downcase.gsub(/\A\s*/, '').chomp.gsub(/\s/, '_').to_sym] = index
    end
    mappings
  end


  ### MISC HELPERS ####

  #Log a message to a file - logs in standard Rails format to logfile set up in the import_products initializer
  #and console.
  #Message is string, severity symbol - either :info, :warn or :error

  def log(message, severity = :info)
    @rake_log ||= ActiveSupport::BufferedLogger.new(IMPORT_PRODUCT_SETTINGS[:log_to])
    message = "[#{Time.now.to_s(:db)}] [#{severity.to_s.capitalize}] #{message}\n"
    @rake_log.send severity, message
    puts message
  end


  ### IMAGE HELPERS ###

  # find_and_attach_image_to
  # This method attaches images to products. The images may come
  # from a local source (i.e. on disk), or they may be online (HTTP/HTTPS).
  def find_and_attach_image_to(product_or_variant, filename)
    return if filename.blank?

    suffix = ['a','b','c','d','e','f','g','h']
    extension = ".jpg"
    first = suffix[0]+extension
    files = []
    if filename.end_with?(first)
      base_filename = filename[0..-1*(first.size+1)]
      suffix.each do |suffix|
        computed_filename = base_filename + suffix + extension
        file = computed_filename =~ /\Ahttp[s]*:\/\// ? fetch_remote_image(computed_filename) : fetch_local_image(computed_filename)
        unless file.nil?
          files << file
        end
      end
    else
      file = filename =~ /\Ahttp[s]*:\/\// ? fetch_remote_image(filename) : fetch_local_image(filename)
      files << file
    end


    files.each do |file|
      #An image has an attachment (the image file) and some object which 'views' it
      product_image = Image.new({:attachment => file,
                                :viewable => product_or_variant,
                                :position => product_or_variant.images.length
                                })

      product_or_variant.images << product_image if product_image.save
    end
  end

  # This method is used when we have a set location on disk for
  # images, and the file is accessible to the script.
  # It is basically just a wrapper around basic File IO methods.
  def fetch_local_image(filename)
    filename = IMPORT_PRODUCT_SETTINGS[:product_image_path] + filename
    unless File.exists?(filename) && File.readable?(filename)
      #log("Image #{filename} was not found on the server, so this image was not imported.", :warn)
      return nil
    else
      return File.open(filename, 'rb')
    end
  end


  #This method can be used when the filename matches the format of a URL.
  # It uses open-uri to fetch the file, returning a Tempfile object if it
  # is successful.
  # If it fails, it in the first instance logs the HTTP error (404, 500 etc)
  # If it fails altogether, it logs it and exits the method.
  def fetch_remote_image(filename)
    begin
      open(filename)
    rescue OpenURI::HTTPError => error
      log("Image #{filename} retrival returned #{error.message}, so this image was not imported")
    rescue
      log("Image #{filename} could not be downloaded, so was not imported.")
    end
  end

  ### TAXON HELPERS ###

  # associate_product_with_taxon
  # This method accepts three formats of taxon hierarchy strings which will
  # associate the given products with taxons:
  # 1. A string on it's own will will just find or create the taxon and
  # add the product to it. e.g. taxonomy = "Category", taxon_hierarchy = "Tools" will
  # add the product to the 'Tools' category.
  # 2. A item > item > item structured string will read this like a tree - allowing
  # a particular taxon to be picked out
  # 3. An item > item & item > item will work as above, but will associate multiple
  # taxons with that product. This form should also work with format 1.
  def associate_product_with_taxon(product, taxonomy, taxon_hierarchy)
    return if product.nil? || taxonomy.nil? || taxon_hierarchy.nil?
    #Using find_or_create_by_name is more elegant, but our magical params code automatically downcases
    # the taxonomy name, so unless we are using MySQL, this isn't going to work.
    taxonomy_name = taxonomy
    taxonomy = Taxonomy.find(:first, :conditions => ["lower(name) = ?", taxonomy])
    taxonomy = Taxonomy.create(:name => taxonomy_name.capitalize) if taxonomy.nil? && IMPORT_PRODUCT_SETTINGS[:create_missing_taxonomies]

    taxon_hierarchy.split(/\s*\&\s*/).each do |hierarchy|
      hierarchy = hierarchy.split(/\s*>\s*/)
      last_taxon = taxonomy.root
      hierarchy.each do |taxon|
        last_taxon = last_taxon.children.find_or_create_by_name_and_taxonomy_id(taxon, taxonomy.id)
      end

      #Spree only needs to know the most detailed taxonomy item
      product.taxons << last_taxon unless product.taxons.include?(last_taxon)
    end
  end
  ### END TAXON HELPERS ###

  # May be implemented via decorator if useful:
  #
  #    ProductImport.class_eval do
  #
  #      private
  #
  #      def after_product_built(product, params_hash)
  #        # so something with the product
  #      end
  #    end
  def after_product_built(product, params_hash)
  end
end
