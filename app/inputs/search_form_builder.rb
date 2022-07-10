class SearchFormBuilder < SimpleForm::FormBuilder
  def input(attribute_name, options = {}, &block)
    options[:input_html] ||= {}
    options[:input_html][:data] = {}
    options[:input_html][:data][:autocomplete] = options[:autocomplete] if options[:autocomplete]
    options = insert_value(attribute_name, options)
    super
  end

  private

  def insert_value(attribute_name, options)
    value = @options[:search_params][attribute_name] || options[:default]&.to_s
    return options if value.nil?

    if options[:collection]
      options[:selected] = value
    elsif options[:as]&.to_sym == :boolean
      options[:input_html][:checked] = true if value.truthy?
    else
      options[:input_html][:value] = value
    end
    options
  end
end
