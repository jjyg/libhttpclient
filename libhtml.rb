# parser HTML
# par Yoann Guillot - 2004

class HtmlElement
	attr_accessor :type, :attr
	def initialize
		@type = nil
		@attr = Hash.new
	end

	def to_s
		'<' + type + attr.map{ |k, v| " #{k}=\"#{v}\"" }.join + '>'
	end
end

def parsehtml(page)
	parse = Array.new
	curelem = nil
	curword = ''
	curattrname = nil
	state = 0
	laststate = 0
	
	# 0: before tag/in string	''
	# 1: in tag type		'<'
	# 2: in tag attrname		'<kikoo '
	# 3: before tag =		'<kikoo lol'
	# 4: before tag attrval		'<kikoo lol='
	# 5: in tag attrval		'<kikoo lol=huu'
	# 6: in tag with "		'<kikoo lol="hoho'
	# 7: in tag with '		'<kikoo lol=\'haha'
	# 8: in comment
	# 9: wait for end of tag	'<kikoo /'
	# 10: in script tag
	
	# stream:  blabla<tag t=tv tg = "tav" tag='t'><kikoo>
	# state:  0000000111122455222344666652222477501111110
	
	# tags take downcase on type and attrname
	
	page.gsub(/\s+/, ' ').gsub(/< /, '<').each_byte { |c|
		c = c.chr
		case state
		when 0 # string
			case c
			when '<'
				if curword.length > 0
					curelem = HtmlElement.new
					curelem.type = 'String'
					curelem.attr['content'] = curword
					parse << curelem
				end
				curword = ''
				curelem = HtmlElement.new
				state = 1
			when ' '
				curword << ' ' if curword.length > 0
			else
				curword << c
			end
		when 1 # after tag start
			if curword == '!--' # html comment
				curword = c
				state = 8
				next
			end
			
			case c
			when '>'
				curelem.type = curword.downcase
				if curelem.type == 'script'
					curword = curelem.to_s
					state = 10
					next
				end
				parse << curelem
				curword = ''
				state = 0
			when '/'
				if curword.length == 0
					# / at the beginning of a tag
					curword = c
				else
					laststate = state
					state = 9
				end
			when ' '
				if curword.length > 0
					# <    kikoospaces lol="mdr">
					curelem.type = curword.downcase
					curword = ''
					state = 2
				end
			else
				curword << c
			end
		when 2 # tagattrname
			case c
			when '>'
				curelem.attr[curword.downcase] = '' if curword.length > 0
				if curelem.type == 'script'
					curword = curelem.to_s
					state = 10
					next
				end
				
				parse << curelem
				curword = ''
				state = 0
			when '/'
				laststate = state
				state = 9
			when ' '
				curattrname = curword.downcase
				curword = ''
				state = 3
			when '='
				curattrname = curword.downcase
				curword = ''
				state = 4
			else
				curword << c
			end
		when 3 # aftertagattrname
			case c
			when '>'
				curelem.attr[curattrname] = ''
				if curelem.type == 'script'
					curword = curelem.to_s
					state = 10
					next
				end
				parse << curelem
				state = 0
			when '/'
				laststate = state
				state = 9
			when '='
				state = 4
			else
				curelem.attr[curattrname] = ''
				curword << c
				state = 2
			end
		when 4 # beforetagattrval
			case c
			when '>'
				curelem.attr[curattrname] = ''
				if curelem.type == 'script'
					curword = curelem.to_s
					state = 10
					next
				end
				parse << curelem
				state = 0
			when '/'
				laststate = state
				state = 9
			when '"'
				state = 6
			when "'"
				state = 7
			when ' '
				# nop
			else
				curword << c
				state = 5
			end
		when 5 # attrval
			case c
			when '>'
				curelem.attr[curattrname] = curword
				if curelem.type == 'script'
					curword = curelem.to_s
					state = 10
					next
				end
				parse << curelem
				curword = ''
				state = 0
			when '/'
				laststate = state
				state = 9
			when ' '
				curelem.attr[curattrname] = curword
				curword = ''
				state = 2
			else
				curword << c
			end
		when 6 # attrval, doublequote
			case c
			when '"'
				state = 5
			else
				curword << c
			end
		when 7 # attrval, singlequote
			case c
			when "'"
				state = 5
			else
				curword << c
			end
		when 8 # comment
			case c
			when '>'
				if (curword[-1].chr == '-' and curword[-2].chr == '-')
					curelem.type = 'Comment'
					curelem.attr['content'] = '<!--'+curword+'>'
					parse << curelem
					curword = ''
					state = 0
				else
					curword << c
				end
			else
				curword << c
			end
		when 9 # wait for end of tag
			if (c != '>')
				curword << '/'
			end
			state = laststate
			c = c[0]
			redo
		when 10 # <script
			if (c == '>' and curword =~ /<\s*\/\s*script\s*$/i)
				curelem.type = 'Script'
				curelem.attr['content'] = curword+'>'
				parse << curelem
				curword = ''
				state = 0
			else
				curword << c
			end
		end
	}
	return parse
end
