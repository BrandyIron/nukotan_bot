require 'capybara'
require 'capybara/user_agent'
require 'selenium-webdriver'
require 'capybara/dsl'
require 'pp'
require 'mongo'
require 'twitter'
require 'open-uri'
load File.expand_path('../../conf/conf.rb', __FILE__)

OpenURI::Buffer.send :remove_const, 'StringMax' if OpenURI::Buffer.const_defined?('StringMax')
OpenURI::Buffer.const_set 'StringMax', 0

class SuperNukotan
	include Capybara::DSL
	def initialize ()
		# configure parameters in capybara
		Capybara.default_driver = :selenium
		Capybara::UserAgent.add_user_agents(your_browser: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/52.0.2743.116 Safari/537.36')
		Capybara.register_driver :selenium do |app|
			Capybara::Selenium::Driver.new(app, :browser => :chrome)
		end

		# establish database connection
		db = Mongo::Client.new(['127.0.0.1:27017'], :database => 'nukotan')
		@coll = db[:articles]

		# configure parameters in twitter oauth
		conf = nukotan_context()

		@client = Twitter::REST::Client.new do |config|
			config.consumer_key = conf[:tweet][:consumer_key]
			config.consumer_secret = conf[:tweet][:consumer_secret]
			config.access_token = conf[:tweet][:access_token]
			config.access_token_secret = conf[:tweet][:access_token_secret]
		end
	end

	def insert_record (record)
		@coll.insert_one(record)
		pp record
	end
end

class Instagram < SuperNukotan
	def initialize ()
		super()
		Capybara.app_host = 'https://www.instagram.com'
		Capybara.visit '/kuroneko_omz'
	end

	def get_newest_info
		doc = Nokogiri::HTML.parse(Capybara.html)
		# elem = doc.css('div._myci9 > a').first
		elem = doc.css('div._myci9').children.first
		newest = {}
		newest[:path] = Capybara.app_host + elem.css('a').first[:href]
		newest[:images] = [elem.css('img').first[:src]]
		newest[:body] = elem.css('img').first[:alt]
		newest[:date] = Time.now.strftime("%Y-%m-%d %H:%M:%S")
		pp newest
		return newest
	end

	def check_newest_info (isprod)
		newest = get_newest_info
	
		if @coll.find({'path' => newest[:path]}).count == 0 then
			p 'Update Instagram: '
			pp newest
			tweet = Tweet.new()
			tweet.send_newest_tweet(isprod, 'instagram', newest)
		end
	end

	def get_archive_info (isinsert)
		f = File.open('./insta_all.html', 'r:utf-8')
		doc = Nokogiri::HTML(f)
		article = {}
		articles = []
		doc.css('a._8mlbc').each do |elem|
			article[:path] = Capybara.app_host + elem[:href]
			article[:images] = [elem.css('img').first[:src]]
			article[:body] = elem.css('img').first[:alt]
			pp article
			articles << article
			insert_record(article) if isinsert
		end
		return articles
	end
			
end

class Nekomamma < SuperNukotan
	def initialize ()
		super()
		Capybara.app_host = 'http://nekomamma.jugem.jp'
		Capybara.visit '/'
	end

	def get_newest_info
		doc = Nokogiri::HTML.parse(Capybara.html)
		elem = doc.css('table.entry').first
		newest = {}
		newests = []
		newest[:title] = elem.css('div.entry_title').text
		newest[:body] = elem.css('div.jgm_entry_desc_mark').text
		images = []
		elem.css('img.pict').each do |image|
			images << image.attribute('src').value
		end
		newest[:images] = images
		
		newest[:path] = Capybara.app_host + elem.css('div.entry_state > a').first[:href].gsub(/\./, '')
		newest[:date] = elem.css('div.entry_date').text.split(' ')[0].gsub(/\./, "-") + ' ' + elem.css('div.entry_state > a').text
		
		splited = split_article_body (newest[:body])
		splited.each do |p|
			newests << {
				:title => newest[:title],
				:path => newest[:path],
				:date => newest[:date],
				:images => newest[:images],
				:body => p,
			}
		end
		pp newests
		return newests
	end

	def check_newest_info (isprod)
		newests = get_newest_info
		if @coll.find({'path' => newests.first[:path]}).count == 0 then
			tweet = Tweet.new()
			tweet.send_newest_tweet(isprod, 'nekomamma', newests.first)
		end
	end

	def get_archive_info (isinsert)
		doc = Nokogiri::HTML.parse(Capybara.html)
		i = 0
		doc.css('div.menu_box').each do |list|
			if i == 3 then
				list.css('a').each do |archive_date|
					Capybara.click_link archive_date.text
					p archive_date.text
					doc = Nokogiri::HTML.parse(Capybara.html)
					doc.css('td.cell > a').each do |article_date|
						p article_date.text
						Capybara.click_link article_date.text
						newests = get_newest_info
						newests.each do |newest|	
							insert_record(newest) if isinsert
						end
					end
				end
			end	
			i += 1
		end
	end

	def split_article_body (article_body)
		splited1 = article_body.gsub(/(\R|[[:space:]])/, '').split("")
		splited2 = []
		tmp = before_p = ""
		isfirst = true
		block_detected = false
		splited1.each do |p|
			if p =~ /（|「/ then
				block_detected = true
				tmp << p
				before_p = p
				next
			end
			if p =~ /）|」/ then
				block_detected = false
				tmp << p
				before_p = p
				next
			end
			if !block_detected then
				if !isfirst && before_p == "！" && p !~ /！|）|」/ then
					splited2 << tmp
					tmp = p
				elsif p =~ /。|？|♪/ then
					splited2 << tmp + p
					tmp = ""
				else
					tmp << p
				end
			else
				tmp << p
			end
			if !isfirst then
				before_p = p
                        end
			isfirst = false
		end
		#pp splited2
	end
end

class Tweet < SuperNukotan
	def initialize
		super()
	end

	def select_tweet
		prng = Random.new()
		@coll.find().skip((prng.rand * @coll.count()).round).limit(1).each do |record|
			pp record
			return record
		end
	end

	def send_stored_tweet(isprod)
		record = select_tweet
		if isprod then
			if record['body'].length >= 90 then
				message = (record['body'])[0, 87] + "...\n" + record['path']
			else 
				message = record['body'] + "\n" + record['path']
			end
			if record['images'].length == 0 then
				@client.update(message)
			else
				media = open(record['images'].sample)
				@client.update_with_media(message, media)
			end
		end
	end

	def send_newest_tweet(isprod, type, newest)
		case
		when type == 'instagram'
			message = "ぬこたんInstagramが更新されました(*´Д`)ﾊｧﾊｧ\n\n"
			if newest[:body].length >= 50 then
				message += (newest[:body])[0, 47] + "...\n"
			else
				message += newest[:body] + "\n"
			end
			message += newest[:path]
			media = open(newest[:images].first)
			@client.update_with_media(message, media) if isprod
		when type == 'nekomamma'
			message = ("黒猫のねこまんま通信が更新されました(*´Д`)ﾊｧﾊｧ\n\n" + newest[:title])[0, 110] + "\n" + newest[:path]
			if newest[:images].length == 0 then
				@client.update(message) if isprod
			else
				media_ids = []
				if isprod then
					newest[:images].each do |image_path|
						media = open(image_path)
						media_ids << @client.upload(media)
					end
					@client.update message, {media_ids: media_ids.join(',')} if isprod
				end
			end
		else
			0
		end
		insert_record(newest)
	end		
end

nuko = Nekomamma.new()


#nuko = Instagram.new()
# nuko.get_newest_info
#nuko.get_archive_info(true)
#nuko.check_newest_info(true)

# nuko = Tweet.new()
# nuko.send_stored_tweet(true)
