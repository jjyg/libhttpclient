#
# librairie emulant un client http
#
# par Yoann Guillot - 2004
#

require 'libhttp'
require 'libhtml'

# full emulation of http client (js ?)

class HttpClientBadGet < RuntimeError
end
class HttpClientBadPost < RuntimeError
end

class HttpClient
	attr_reader :path, :cookie, :get_url_allowed, :post_allowed, :cache, :cur_url, :curpage, :history, :links, :http_s
	attr_accessor :bogus_site, :referer, :allowbadget

	def initialize(url)
		if not url.include? '://'
			url = "http://#{url}"
		end
		if ENV['http_proxy'] =~ /^http:\/\/(.*?)\/?$/
			url = "http-proxy://#$1/#{url}"
		end
		@http_s = HttpServer.new(url)
		@bogus_site = false
		@allowbadget = false
		@next_fetch = Time.now
		clear
	end

	def status_save
		[@path, @get_url_allowed, @post_allowed, @referer, @curpage, @cur_url].map { |o| o.dup rescue o }
	end

	def status_restore(s)
		 @path, @get_url_allowed, @post_allowed, @referer, @curpage, @cur_url = *(s.map { |o| o.dup rescue o })
	end
	
	def clear
		@post_allowed = Array.new
		@get_url_allowed = Array.new
		@history = Array.new
		@cache = Hash.new
		@cookie = Hash.new
		@referer = nil
		@path = '/'
		@cur_url = nil
		@curpage = nil
	end
	
	def inval_cur
		@cur_url = nil
		@curpage = nil
	end
	
	def sess_headers
		h = Hash.new
		if not @cookie.empty?
			h['Cookie'] = @cookie.map { |k, v| "#{k}=#{v}" }.join('; ')
		end
		if @referer
			h['Referer'] = @referer
		end
		h
	end

	def abs_path(url, update_class = false)
		path = @path.clone
		url = $1 if url =~ /^http:\/\/#{Regexp.escape @http_s.host}(\/.*)/
		if (url =~ /^(\/(?:[^?]+\/)?)(.*?)$/)
			# /, /url, /url/url, /url/url?url/url
			path = $1
			page = $2
		elsif (url =~ /^([^?]+\/)(.*?)$/)
			# url/url, url/url?url/url
			relpath = $1
			page = $2

			# handle ../
			while relpath[0..2] == '../'
				path.sub!(/\/[^\/]+\/$/, '/')
				relpath = relpath[3..-1]
			end
			
			# skip ./
			while relpath[0..1] == './'
				relpath = relpath[2..-1]
			end
			
			path += relpath
		else
			# url, url?url/url
			page = url.dup
		end
		
		page.sub!(/#[^?]*/, '')
		if (page == '..')
			page = ''
			path.sub!(/\/[^\/]+\/$/, '/')
		end
		
		@path = path if update_class
		return path+page
	end

	def fetch_next_now
		@next_fetch = Time.now
	end
	
	def get(url, timeout=nil, recursive=false)
		url.gsub!(' ', '%20')

		url = abs_path(url, (not recursive))

		return @curpage if url == @cur_url
		
		if not @allowbadget and not recursive and not @get_url_allowed.empty? and not @get_url_allowed.include?(url.sub(/\?.*$/, ''))
			puts "Forbidden to get #{url} from here ! We are at #{@cur_url}, allowed list: #{@get_url_allowed.sort.join(', ')}" rescue nil
			raise HttpClientBadGet.new(url)
		end
		
		if not recursive
			@history << url
			diff = @next_fetch.to_f - Time.now.to_f
			sleep diff if diff > 0
			timeout ||= (rand(8) == 0) ? (1+rand(40)) : (1+rand(6))
				
			@next_fetch = Time.now + timeout
			@cur_url = url
		end

		page = @http_s.get(url, sess_headers)
		page = analyse_page(url, page, recursive)

		@curpage = page if not recursive
		
		return page
	end

	def post_raw(url, postdata, headers={})
		url = abs_path(url, true)
		
		diff = @next_fetch.to_i - Time.now.to_i
		sleep diff if diff > 0
		timeout = (1+rand(6))
		@next_fetch = Time.now + timeout

		@cur_url = url
		@history << 'postraw:'+url
		page = @http_s.post_raw(url, postdata, sess_headers.merge(headers))
		page = analyse_page(url, page)
		@curpage = page
		
		return page
	end

	def post(url, postdata, timeout=nil, pretimeout=nil)
		url = abs_path(url, true)
		
		allow = false
		@post_allowed.each { |p|
			if p.url == url
				allow = true
				p.verify(postdata)
			end
		}
		if not @allowbadget and not allow
			puts "Form action unknown here ! cur: #{@cur_url}, action: #{url}" rescue nil
			raise HttpClientBadPost.new(url)
		end
		
		
		pretimeout ||= (rand(5) == 1) ? (3+rand(25)) : (1+rand(4))
		diff = @next_fetch.to_i - Time.now.to_i + pretimeout
		sleep diff if diff > 0
		timeout ||= (rand(4) == 1) ? (3+rand(15)) : (1+rand(4))
		@next_fetch = Time.now + timeout

		@cur_url = url
		@history << 'post:'+url
		page = @http_s.post(url, postdata, sess_headers)
		page = analyse_page(url, page)
		@curpage = page
		
		return page
	end

	# TODO need a rewrite
	def analyse_page(url, page, recursive=false)
		raise RuntimeError.new('No page... Timed out ?') if not page
		if (page.headers['set-cookie'])
			page.headers['set-cookie'].split(/\s*;\s*/).each { |c|
				if c =~ /^([^=]*)=(.*)$/
					name, val = $1, $2
					if not ['path', 'domain', 'expires'].include?(name)
						if (val == 'deleted')
							@cookie.delete(name)
						else
							@cookie[name] = val
						end
					end
				end
			}
		end
		
		case page.status
		when 301, 302
			newurl = page.headers['location'].sub(/#[^?]*/, '')
#			puts "#{url} => 302 to #{newurl}" if newurl !~ /^[0-9a-zA-Z.:\/-]*$/ and page.status == 302 rescue nil
			puts "#{url} => 301 to #{newurl}" if page.status == 301 rescue nil
			case newurl
			when /^http:\/\/#{@http_s.host}(.*)$/, /^(\/.*)$/
				newurl = $1
				if newurl =~ /^(.*?)\?(.*)$/
					newurl, gdata = $1, $2
					newurl += '?' +
					gdata.split('&').map{ |e| e.split('=', 2).map{ |k| HttpServer.urlenc(k) }.join('=') }.join('&')
				end
				@get_url_allowed << newurl.sub(/[?#].*$/, '') if not recursive
				return get(newurl, 0, recursive)
			when /^https?:\/\//
				puts "Will no go to another site ! (#{url} is a 302 to #{newurl})" rescue nil
				return page
			else
				raise RuntimeError.new("No location for 302 at #{url}!!!") if not newurl
				newurl = abs_path(newurl)
				@get_url_allowed << newurl.sub(/[?#].*$/, '') if not recursive
				return get(newurl, 0, recursive)
			end
		when 401, 403, 404
			puts "Error #{page.status} with url #{url} from #{@referer}" if not @bogus_site rescue nil
			@cache[url] = page
			return page
		when 200
			# noreturn
		else
			puts "Error code #{page.status} with #{url} from #{@referer} :\n#{page}" rescue nil
			return page
		end
			
		@cache[url] = page
		
		return page if recursive or (page.headers['content-type'] and page.headers['content-type'] !~ /text\/(ht|x)ml/)
		
		@referer = 'http://' + @http_s.host + url
		
		@get_url_allowed.clear
		@get_url_allowed << url.sub(/[#?].*$/, '')
		@post_allowed.clear

		get_allow = Array.new
		to_fetch = Array.new
		page.parse = parsehtml(page.content)
		
		postform = nil
		page.parse.each { |e|
			case e.type
			when 'img', 'Script'
				to_fetch << e.attr['src']
			when 'iframe'
				get_allow << e.attr['src']
			when 'frame'
				get_allow << e.attr['src']
			when 'a'
				get_allow << e.attr['href']
			when 'link'
				to_fetch << e.attr['href']
			when 'form'
				# default target
				tg = url.sub(/[?#].*$/, '')
				if e.attr['action'] and e.attr['action'].length > 0
					tg = e.attr['action']
					tg = abs_path(tg) if tg !~ /^https?:\/\// or tg =~ /^http:\/\/#{Regexp.escape @http_s.host}\//
				end
				if e.attr['method'] and e.attr['method'].downcase == 'post'
					postform = PostForm.new tg unless postform and postform.url == tg
				else
					get_allow << tg
				end
			when '/form'
				if postform
					@post_allowed << postform
					postform = nil
				end
			end
			
			postform.sync_elem(e) if postform
			
			to_fetch << e.attr['background'] if e.attr['background']
		}
		@post_allowed << postform if postform

		@links = to_fetch + get_allow unless recursive
		
		to_fetch_temp = Array.new
		to_fetch.each { |u|
			case u
			when '', nil
			when /^(?:http:\/\/#{@http_s.host})?(\/[^?]*)(?:\?(.*))?/i
				if $2
					to_fetch_temp << (HttpServer.urlenc($1) + '?' + $2)
				else
					to_fetch_temp << HttpServer.urlenc($1)
				end
			when /^https?:\/\//i, /^mailto:/i, /^javascript/i, /\);?$/
			else
				if u =~ /([^?]*)\?(.*)/
					u = HttpServer.urlenc(abs_path($1)) + '?' + $2
				else
					u = HttpServer.urlenc(abs_path(u))
				end
				to_fetch_temp << u
				puts "Debug: to_fetch add catchall #{u.inspect}" if u !~ /^[a-zA-Z0-9._\/?=&;#%!-]*$/ and not @cache.has_key?(u) and not @bogus_site rescue nil
			end
		}
		
		to_fetch = to_fetch_temp.uniq - @cache.keys
#puts "for #{url}: recursing to #{to_fetch.sort.inspect}"
		to_fetch.each { |u|
			get(u, 0, true)
		}
		
		get_allow.each { |u|
			case u
			when /^http:\/\/#{@http_s.host}(\/[^?#]*)/i
				@get_url_allowed << $1
			when /^(\/[^?#]*)/
				@get_url_allowed << $1
			when nil
			when /^https?:\/\//i
			when /^mailto:/i
			when /^javascript/i, /\);?$/
			else
				if u.length > 0
					nu = abs_path(u).sub(/[?#].*$/, '')
					@get_url_allowed << nu
				end
				puts "Debug: get_allow add catchall #{u.inspect}" if u !~ /^[a-zA-Z0-9._\/=?&;#%!-]*$/ and not @bogus_site rescue nil
			end
		}

		@get_url_allowed.uniq!
		@post_allowed.uniq!
		
		return page
	end
	
	def to_s
		"Http Client for #{@http_s.host}: current url #{@cur_url}\n"+
		"Cookies: #{@cookie.inspect}\n"+
		"Cache: #{@cache.keys.sort.join(', ')}\n"+
		"Get allowed: #{@get_url_allowed.sort.join(', ')}\n"+
		"post allowed: #{@post_allowed.sort.join(', ')}"
	end

	def inspect
		"#<HttpClient: site=#{@http_s.host.inspect}, @cur_url=#{@cur_url.inspect}>"
	end
end

class PostForm
	attr_reader :url, :vars, :mandatory
	
	# vars is a hash, key = name of each var for the form,
	#   value = 'blabla' if var has default value (for input and textarea)
	#   value = ['bla', 'blo', 'bli'] for <select><option>, [0] = default value
	#   value = nil if no default value (or if <select> empty)
	
	def initialize(url)
		@url = url
		@vars = Hash.new
		@mandatory = Hash.new
		@textarea_name = nil
	end

	def eql?(other)
		return false unless @url.eql?(other.url)
		@mandatory.each_key { |k|
			return false unless other.mandatory.has_key?(k)
			return false unless @mandatory[k].eql?(other.mandatory[k])
		}
		other.mandatory.each_key { |k| return false unless @mandatory.has_key?(k) }
		return true
	end

	def hash
		h = @url.hash
		@mandatory.each_key { |k| h += @mandatory[k].hash }
		return h
	end

	def sync_elem(e)
		case e.type
		when 'input'
			if e.attr['name']
				if e.attr['type'].downcase == 'radio'
					(@vars[e.attr['name']] ||= []) << e.attr['value']
				else
					(@opt_vars ||= []) << e.attr['name'] if e.attr['type'].downcase == 'checkbox'
					@vars[e.attr['name']] = e.attr['value']
					@mandatory[e.attr['name']] = e.attr['value'] if e.attr['value'] and e.attr['type'] and e.attr['type'].downcase == 'hidden' and e.attr['name'] !~ /\[\]/
				end
			elsif e.attr['type'].downcase == 'image'
				@vars['x'] = rand(15).to_s
				@vars['y'] = rand(10).to_s
			end
		
		when 'textarea'
			@textarea_name = e.attr['name']
		when '/textarea'
			if @textarea_name
				@vars[@textarea_name] = ''
				@textarea_name = nil
			end
		
		when 'select'
			@select_name = e.attr['name']
			@vars[@select_name] = [] if @select_name
		when '/select'
			if @select_name and @vars[@select_name].empty?
				@vars[@select_name] = nil
			end
			@select_name = nil	
		when 'option'
			if @select_name and e.attr['value']
				@vars[@select_name] << e.attr['value']
			end
		
		when 'String'
			if @textarea_name
				@vars[@textarea_name] = e.attr['content']
				@textarea_name = nil
			end
		end
	end

	def verify(postdata, debug=false)
		@mandatory.each_key { |k|
			if @mandatory[k] != postdata[k]
				puts "verif postdata: mandatory var #{k.inspect} set to #{postdata[k].inspect}, should be #{@mandatory[k].inspect}" if $DEBUG rescue nil
				return false
			end
		}
		
		postdata.each_key { |k|
			if not @vars.has_key?(k)
				puts "Postdata check: posting unknown variable #{k.inspect}" if $DEBUG rescue nil
				return false
			end
		}
		
		@vars.each_key { |k|
			if not postdata[k] # var not submitted: check for a default value
				if not @vars[k]
					puts "Postdata check: unfilled varname #{k.inspect} - no default" if $DEBUG rescue nil
					return false
				else
					dval = @vars[k]
					dval = dval[0] if dval.class == Array
					postdata[k] = dval unless @opt_vars.to_a.include? k
					puts "Postdata check: set default value '#{dval.inspect}' for #{k.inspect}" if $DEBUG rescue nil
				end
			end
		}
		
		return true
	end
	
	def to_s
		"PostForm: url #{@url} ; vars: #{@vars.inspect} (mandatory: #{@mandatory.keys.inspect})"
	end
end
