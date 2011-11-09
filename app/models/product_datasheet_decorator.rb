ProductDatasheet.class_eval do
  
  def processor=(value)
    @processor=value
  end

  def processor
    self.class.to_s
  end
end

