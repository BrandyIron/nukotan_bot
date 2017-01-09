require File.expand_path('../main.rb', __FILE__)

nekomamma = Nekomamma.new()
nekomamma.check_newest_info(true)

instagram = Instagram.new()
instagram.check_newest_info(true)
