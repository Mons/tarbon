if gr == nil then
	gr = { version = 1.0 };
else
	gr.version = 1.0
end
-- gr['defschema'] = '1s30s 1s7d 1m3M'
gr.snaphost = box.cfg.bind_ipaddr
if gr.snaphost == nil then gr.snaphost = '127.0.0.1' end
gr.snapport = box.cfg.admin_port
if gr.snapport == nil then gr.snapport = 33015 end

gr.snapevery = 600
gr.schemas = {
	{ pattern = '^test%.',     schema = '1s1h 1m5d 10m3M 1h1y' };
	{ pattern = '^monit%.',    schema = '1s5d 10m3M 1h1y' };
	{ pattern = '^mon%.',      schema = '1s1h 1m5d 10m3M 1h1y' };
	{ pattern = '^filin%.',    schema = '1s5d 10m3M 1h1y' };
	{ pattern = '^cloud%.',    schema = '1s5d 10m3M 1h1y' };
	{ pattern = '%.1sec%.',    schema = '1s5d 10m3M 1h1y' };
	{ pattern = '%.1min%.',    schema = '1m1w 10m3M 1h1y' };
	{ pattern = '%.5min%.',    schema = '5m1w 10m3M 1h1y' };
	{ pattern = '%.10min%.',   schema = '10m3M 1h1y' };
	{ pattern = '.+',          schema = '1m1M 10m3M 1h1y' };
}
gr['defagg'] = 'avg'

gr.port = 22003

-- metrics (name=STR, schemas=STR, agg=STR)
METRICS = 0
MNAME   = 0
MSCHEMA = 1
MAGG    = 2

-- idents ( id=INT, name = STR, schema = STR)
IDENTS  = 1
IID     = 0
INAME   = 1
ISCHEMA = 2

-- counters (metric_id=INT, timeslot=INT, value=BIGINT, count=STR (int16), time=INT )
COUNTERS = 2
CID     = 0
CSLOT   = 1
CVALUE  = 2
CCOUNT  = 3
CTIME   = 4

function gr.mult (x)
	if (x == 's') then return 1
	elseif ( x == 'm' ) then return 60
	elseif ( x == 'h' ) then return 3600
	elseif ( x == 'd' ) then return 3600*24
	elseif ( x == 'w' ) then return 3600*24*7
	elseif ( x == 'M' ) then return 3600*24*30
	elseif ( x == 'y' ) then return 3600*24*365
	else error("Unknown type '" .. x .. "'")
	end
end

function gr.st1t (x)
	local a,b = string.match(x,'(%d+)(%a+)')
	return tonumber(a) * gr.mult(b)
end

function gr.sch2pair (x)
	local d1,s1,d2,s2 = string.match(x,'(%d+)(%a+):*(%d+)(%a+)%s*')
	d1 = d1 * gr.mult(s1)
	return d1 , math.floor(d2 * gr.mult(s1)/d1)
end


function gr.st2t (x)
	local ret = {};
	for d1,s1,d2,s2 in string.gmatch(x,'(%d+)(%a+):*(%d+)(%a+)%s*') do
		local sk = d1..s1..d2..s2
		d1 = d1 * gr.mult(s1)
		d2 = math.floor(d2 * gr.mult(s2) / d1)
		ret[#ret+1] = { d1,d2,sk };
	end
	return ret;
end

function rrd_it_fw(schema, now, from_time, till_time)
	-- if type(m_id) == 'number' then m_id = box.pack('i',m_id) end
	local id = box.unpack('i',schema[IID])
	local sk = schema[ISCHEMA]
	
	if now == nil then now = os.time() end
	local i = box.space[COUNTERS].index[0]
	local s1,s2 = gr.sch2pair(sk)
	local oldest = now - math.floor( s1*s2 );
	if ( from_time == nil or from_time < oldest ) then
		print("set from time to ",oldest)
		from_time = oldest + 1
	end
	if ( till_time == nil or till_time > now ) then
		print("set till time to ",now)
		till_time = now
	end
	if from_time >= till_time or till_time < oldest then
		print("bad config ", from_time, ' !< ', till_time, ' !< ', oldest)
		return function() return nil end
	end
	
	print("created forward iterator now = ",now,"; ",id,':',sk,':',curslot, " ; ",s1, " ",s2, ' from ', from_time, '+ -> ', till_time)
	
	--     ->           second     <- ->             first              <-
	-- v1: 0                   -> curslot -> flom_slot -> till_slot -> end
	-- v2: 0 ->  till_slot     -> curslot -> flom_slot              -> end
	-- v3: 0 ->  from -> till  -> curslot ->                        -> end
	
			print("iterator from (",from_time, ' till ',till_time,']')
			from_time = math.floor(from_time/s1)
			till_time = math.floor(till_time/s1)
			oldest = math.floor(oldest/s1)
			print("iterator from ",oldest," -> (",from_time, ' till ',till_time,']')
			local ctime = from_time
			return function ()
				ctime = ctime + 1
				if ctime > till_time then return nil end
				print("compare ",from_time,' -> ',ctime,' -> ',till_time)
				local slot = ctime % s2
				local s = box.select(COUNTERS,0,{id,slot})
				print(s)
				if s == nil then
					return false
				elseif (box.unpack('i',s[CTIME]) < oldest) then
					--print('obsolete')
					return false
				else
					return s
				end
			end
end

function rrd_it_rv(schema, now, from_time, till_time)
	-- if type(m_id) == 'number' then m_id = box.pack('i',m_id) end
	local id = box.unpack('i',schema[IID])
	local sk = schema[ISCHEMA]
	
	if now == nil then now = os.time() end
	local i = box.space[COUNTERS].index[0]
	local s1,s2 = gr.sch2pair(sk)
	local oldest = now - math.floor( s1*s2 );
	if ( from_time == nil or from_time < oldest ) then
		--print("set fromtime to ",oldest)
		from_time = oldest
	end
	if ( till_time == nil or till_time > now ) then
		--print("set till time to ",now)
		till_time = now
	end
	if from_time >= till_time or till_time < oldest then
		print("bad config ", from_time, ' !< ', till_time, ' !< ', oldest)
		return function() return nil end
	end
	
	print("created reverse iterator now = ",now,"; ",id,':',sk,':',curslot, " ; ",s1, " ",s2, ' from ', from_time, '+ -> ', till_time)
	
	--     ->           second     <- ->             first              <-
	-- v1: 0                   -> curslot -> flom_slot -> till_slot -> end
	-- v2: 0 ->  till_slot     -> curslot -> flom_slot              -> end
	-- v3: 0 ->  from -> till  -> curslot ->                        -> end
	
			print("iterator from (",from_time, ' till ',till_time,']')
			local from_time = math.floor(from_time/s1)
			local till_time = math.floor(till_time/s1)
			local ctime = till_time
			return function ()
				ctime = ctime - 1
				if ctime < from_time then return nil end
				local slot = ctime % s2
				local s = box.select(COUNTERS,0,{id,slot})
				if s == nil then
					return false
				elseif (box.unpack('i',s[CTIME]) < oldest) then
					--print('obsolete')
					return false
				else
					return s
				end
			end
end

function rrd_it_rv1(m_id, sk, now)
	if now == nil then now = os.time() end
	local i = box.space[1].index[0]
	local s1,s2 = gr.sch2pair(sk)
	local oldest = now - math.floor( s1*s2 );
	local slots = math.floor( s2/s1 )
	local curslot = math.floor( now/s1 ) % s2
	print("created reverse iterator ",box.unpack('i',m_id),':',sk,':',curslot, " ; ",s1, " ",s2)
	local it = i:iterator( box.index.LE, m_id,sk,curslot )
	local second = false
	local s
	-- 1: 0 <- maxslot
	-- 2: maxslot <- slots
	return function()
		while true do
			s = it()
			if s == nil or ( not second and s[1] ~= sk ) or ( second and box.unpack('i',s[2]) < curslot + 1 ) then
				if (second) then
					s = nil
					it = nil
					return nil
				else
					print("switch to second")
					it = i:iterator( box.index.LE, m_id,sk,slots )
					s = it()
					if s == nil or box.unpack('i',s[2]) < curslot + 1 then
						it = nil
						return nil
					end
					second = true
				end
			end
			if (box.unpack('i',s[5]) >= oldest) then
				--print(s)
				return s
			else
				-- print("skip obsolete")
			end
		end
	end
end

function gr.find(query)
	local qq
	qq = string.gsub( query, '([%^%$%(%)%%%.%[%]%+%-%?])', '%%%1' );
	qq = string.gsub( qq, '%*', '[^%.]+' );
	local qx = '^('..qq..')%.([^%.]+)'
	qq = '^('..qq..')'
	local ret = {}
	local seen = {}
	for k,v in box.space[METRICS]:pairs() do
		local m = v[ MNAME ]
		--print("match '",m,"' against '",query,"' = '",qq,"' / '",qx,"'")
		if (string.match( m,qq ) ~= nil) then
			local a,b = string.match(m, qx)
			--if a ~= nil then
			print("matched ",m,": ",a,' + ',b)
			if (b ~=nil) then
				if (seen[b]) then
					-- print("already saved ",b)
				else
					ret[#ret+1] = {
						-- intervals = arr;
						metric_path = a;
						isLeaf = false;
					}
					seen[b] = true
				end
			else
				local schemas = gr.st2t(v[MSCHEMA]);
				local schema = schemas[#schemas]
				local s1,s2,sk = unpack(schema)
				print("leaf ",m,sk)
				local schrec = box.select(IDENTS, 1, { m, sk })
				print(schrec)
				local id = schrec[IID]
				local mintime;
				local maxtime;
if (false) then				
				local it = rrd_it_fw( schrec )
				while true do
					local s = it()
					print(s)
					if s == nil then break end
					if s then mintime = box.unpack('i',s[CTIME]) break end
				end
				print("mintime = ",mintime)
				
				local it = rrd_it_rv( schrec )
				while true do
					local s = it()
					if s == nil then break end
					if s then maxtime = box.unpack('i',s[CTIME]) break end
				end
				
				print("maxtime = ",maxtime)
end
				if (mintime ~= nil and maxtime ~= nil) then
					ret[#ret+1] = {
						intervals = {mintime,maxtime};
						metric_path = m;
						isLeaf = true;
					}
				else 
					ret[#ret+1] = {
						metric_path = m;
						isLeaf = true;
					}
				end
			end
			--else
			--	print("regexp misconfig ",m,' ',qq, ' ',qx)
			--end
		else
			-- print("not matched")
		end
	end
	return box.cjson.encode(ret)
end

function gr.save(metric,value,time)
	if (time == nil) then time = os.time() end
	local m
	while true do
		m = box.select(METRICS,0,metric);
		if (m == nil) then
			local sch
			local agg
			for i,schema in pairs(gr.schemas) do
				if string.match(metric,schema.pattern) then
					if schema.schema then
						sch = schema.schema
					end
					if schema.agg then
						agg = schema.agg
					else
						agg = gr.defagg
					end
					break;
				end
			end
			print("create ",metric," with  ",sch,'; agg=',agg)
			local r,e = pcall(box.insert, METRICS, { metric, sch, agg })
			if (not r) then
				print("insert ",n,':',metric," failed: ",e)
				break;
			else
				m = e
				break;
			end
		else
			break;
		end
	end
	--if m == nil then return end
	--		local v = box.space[0].index[0]:max()
	--		local n
	--		if v == nil then n = 1 else n = box.unpack('i',v[0]) + 1 end
	value = tonumber(value)
--	print(m)
	local schemas = gr.st2t(m[MSCHEMA]);
	local agg = m[MAGG];
	for n,schema in pairs(schemas) do
		local s1,s2,sk = unpack(schema)
		local id
		
		while (true) do
			local schrec = box.select(IDENTS, 1, metric, sk)
			if schrec == nil then
				print(" need to create ",metric," ",sk)
				local v = box.space[IDENTS].index[0]:max()
				print("selected max: ",v)
				if v == nil then id = 1 else id = box.unpack('i',v[CID]) + 1 end
				local r,e = pcall(box.insert, IDENTS, { id, metric, sk })
				if (not r) then
					print("insert ",id,' ', metric,' ', sk," failed: ",e)
				else
					break
				end
			else
				id = box.unpack('i',schrec[CID])
				break
			end
		end
		-- print( metric,' ',sk,' id=',id )
		
		local t = math.floor(time / s1);
		local mintime = os.time() - s2*s1
		local slot = t % s2;
		-- print("save ",sk,' ',metric,' ',time, ' -> ',slot)
		if (agg == 'last') then
			local x = box.update(1,{m[0],slot},'=p',2,value)
			if (not x) then
				local r,e = pcall(box.insert,1, { m[0],slot,value })
				if (not r) then
					print("insert ",m[0]," failed: ",e)
					x = box.update(1,{m[0],slot},'=p',2,value)
				else
					x = e
				end
			end
		elseif (agg == 'avg') then
			-- id,schema,slot,value,count,time
			-- 0  1      2    3     4     5
			
			local call = function()
			local x = box.select(COUNTERS,0,{id,slot})
			if (x == nil) then
				--print("insert ",metric,'=',value, ' at ',time)
				box.insert(COUNTERS,{ id,slot,box.pack('l',value),box.pack('s',1), box.pack('i',time) })
			-- elseif box.unpack('i',x[CTIME]) < mintime or box.unpack('i',x[CTIME]) ~= time then
			elseif box.unpack('i',x[CTIME]) < mintime then
				--print("replace ",metric,'=',value, ' at ',time)
				-- print("replace ",box.unpack('i',x[5]), " -> ", time)
				box.replace(COUNTERS,{ id,slot,box.pack('l',value),box.pack('s',1), box.pack('i',time) })
			else
				local count = box.unpack('s',x[CCOUNT])
				if (count >= 65535) then
					-- print("aggregation limit for ", metric, ' at ',time)
				else
					local val = tonumber(box.unpack('l',x[CVALUE]))
					--print("aggregate [",slot,"]",metric,' = (',val,'/',count,') +=',value, ' at ',time)
					count = count + 1
					val = ( val+value ) / count
					-- print("update ",box.unpack('i',x[4]), ' ',time, ' -> ', box.unpack('i',x[5]))
					box.update(COUNTERS, { id,slot }, '=p=p=p', CVALUE, box.pack('l',value), CCOUNT, box.pack('s',count), CTIME, box.pack('i',time) )
				end
			end
			end
			while true do
				local r,e = pcall(call)
				if not r then
					if string.match(e,'Failed to allocate') then
						print("allocate error: ",e)
						local prev
						local it = box.space[COUNTERS].index[0]:iterator( box.index.GE, id, slot + 1 )
						local s = it()
						if (s == nil or box.unpack('i',s[CID]) ~= id ) then
							it = box.space[COUNTERS].index[0]:iterator( box.index.GE, id, 0 )
							local s = it()
							if (s == nil or box.unpack('i',s[CID]) ~= id ) or box.unpack('i',s[CSLOT]) >= slot  then
								s = nil
							end
						end
						if s ~= nil then
							print("found prev slot ",box.unpack('i',s[CSLOT]), " before ",slot)
							box.delete(COUNTERS,s[CID],s[CSLOT])
						else
							break
						end
					else
						print("error: ",e)
						break
					end
				else
					-- print("success for ",metric)
					break
				end
			end
		else
			print("unsupported aggregation: ",agg)
		end
	end
	return
end

function gr.points(metric,from,till)
	print("requested points for ",metric, ' (', from,' -> ',till,']')
	-- if true then return '[]' end
	if till == nil then till = os.time() end
	local range = till - from
	from = tonumber(from)
	till = tonumber(till)
	
	local m = box.select(METRICS,0,metric);
	if m == nil then return nil end
	print("got range ",range," for ",m, ' from ',from, '+ till ', till);
	local schemas = gr.st2t(m[MSCHEMA]);
	local schema
	local points
	for n,sch in pairs(schemas) do
		local s1,s2,sk = unpack(sch)
		local prange = math.floor(range/s1)
		print(sk, ' ',s1, ' ', s2, '; points by range ',prange,'; time back = ',s2*s1)
		schema = sch
		points = math.floor((till - from)/s1)
		if ( os.time() - from <= s2*s1 ) then
			break;
		else
			print(sk, " is too small. need ", points, ' points, have ',s2*s1)
		end
	end
	local s1,s2,sk = unpack(schema)
	schema = box.select(IDENTS, 1, { metric, sk })
	local now = os.time()
	local oldest = now - s2*s1 + 1
	local id = box.unpack('i',schema[IID])
	
	print("use ",schema,' ',s1, ' ',s2, '; points = ',points );
	local rv = {
		step = s1;
		name = metric;
		start = from;
	}
	rv['end'] = till;
	local val = {}
	
	local maxpoints = 2000
	local aggcnt = math.ceil(points/maxpoints)
	local shift = (from+1)%aggcnt-1
	rv['step'] = aggcnt*s1
	print("averaging ",aggcnt)
	local agg = 0
	local cnt = 0
	for cur = from+1,till,s1 do
		local v
		if cur < oldest then
			v = 0
		else
			local slot = math.floor(cur / s1) % s2;
			local s = box.select(COUNTERS,0,{id,slot})
			if s == nil or (box.unpack('i',s[CTIME]) < oldest) then
				v = 0
			else
				if (#s[3] == 4) then
					v = tonumber(box.unpack('i',s[CVALUE]))
				else
					v = tonumber(box.unpack('l',s[CVALUE]))
				end
			end
		end
		--print (cur," / ",( cur - shift ) % aggcnt)
		agg = agg + v
		cnt = cnt + 1
		if (( cur - shift ) % aggcnt == 0) then
			val[#val+1] = agg/cnt
			agg = 0
			cnt = 0
		end
	end
	if (cnt > 0) then	
		val[#val+1] = agg/cnt
	end
	rv['values'] = val
	--print("datapoints: ",#val)
	return box.cjson.encode({rv})
end

function gr.saveline(line)
		local metric,value,time = string.match(line, '([^%s]+) ([%d.]+)%s*(%d*)')
		if (metric ~= nil) then
			value = tonumber(value)
			if time ~= '' then
				time = tonumber(time)
			else
				time = os.time()
			end
			-- print(metric,'; ',value, '; ',time)
			gr.save(metric,value,time)
		else
			print("got malformed line ",line)
		end
end

function gr.mon()
	local now = os.time()
	gr.save("self.arena.size",box.slab.arena_size,now)
	gr.save("self.arena.used",box.slab.arena_used,now)
	local items = 0
	for k,v in pairs(box.slab.slabs) do
		items = items + v.bytes_used
	end
	-- print("save mon, arena:", tonumber(items), ' -> ', tonumber(box.slab.arena_used), ' <- ',tonumber(box.slab.arena_size))
	gr.save("self.arena.items",items,now)
	for k,v in pairs(box.space) do
		if k == METRICS then
			gr.save("self.space.metrics",v:len(),now)
		elseif k == IDENTS then
			gr.save("self.space.idents",v:len(),now)
		elseif k == COUNTERS then
			gr.save("self.space.counters",v:len(),now)
		else
			gr.save("self.space."..k,v:len(),now)
		end
	end
end

function gr.worker(sock,host,port)
	box.fiber.detach()
	box.fiber.name("gr.worker."..host..":"..port)
	print("worker");
	while true do
		local line = sock:readline()
		if (line == nil or line == '') then
			print("closing connection");
			sock:close()
			break;
		end
		gr.saveline(line)
	end
end

function gr.tcpserver()
	box.fiber.detach()
	box.fiber.name("gr.tcpserver")
	while true do
		local sock, status, host, port = gr.tcpsrv:accept()
		if (sock ~= nil) then
			print ("accepted ",host,":",port);
			local wfiber = box.fiber.create(gr.worker)
			box.fiber.resume(wfiber, sock,host,port)
		else
			print ("accept failed ", status, host,port);
		end
		
	end
end

function gr.udpserver()
	box.fiber.detach()
	box.fiber.name("gr.udpserver")
	while true do
		local msg, status, host, port = gr.udpsrv:recvfrom(10000)
		if (msg ~= '') then
			for v in string.gmatch(msg,'([^\n]+\n)') do
				local r,e = pcall(gr.saveline,v)
				if (not r) then
					print("saveline failed: ",e)
					break;
				end
			end
		else
			print("not a message ", status, host, port);
		end
	end
end

if (gr.tcpsrv == nil) then
	local sock = box.socket.tcp()
	sock:bind('0.0.0.0', gr.port, 1);
	sock:listen()
	print("bound to tcp port ",gr.port)
	local f = box.fiber.create(gr.tcpserver)
	box.fiber.resume(f)
	gr.tcpsrv = sock;
end

if (gr.udpsrv == nil) then
	local sock = box.socket.udp()
	sock:bind('0.0.0.0', gr.port, 1);
	sock:listen()
	print("bound to udp port ",gr.port)
	local f = box.fiber.create(gr.udpserver)
	box.fiber.resume(f)
	gr.udpsrv = sock;
end

if gr.selfmon == nil then
	gr.selfmon = box.fiber.create(function()
		box.fiber.detach()
		box.fiber.name("gr.monitor")
		while true do
			box.fiber.testcancel()
			local r,e = pcall(gr.mon)
			if (not r) then
				print("gr.mon error: ",e)
			end
			box.fiber.sleep(1)
		end
	end)
	box.fiber.resume(gr.selfmon)
end

function gr.savesnap()
	print("saving snapshot")
	local sock = box.socket.tcp()
	local s,status,err = sock:connect(gr.snaphost,gr.snapport,1)
	if (not s or s == 'error') then print("connect error: ",s,status) return end
	sock:send("save snapshot\n")
	local line = sock:readline()
	print(line)
	sock:close()
end

gr.dosnap = nil
if gr.dosnap == nil then
	gr.dosnap = box.fiber.create(function()
		box.fiber.detach()
		box.fiber.name("gr.makesnap")
		while true do
			box.fiber.testcancel()
			box.fiber.sleep(gr.snapevery)
			local r,e = pcall(gr.savesnap)
			if (not r) then
				print("gr.savesnap error: ",e)
			end
		end
	end)
	box.fiber.resume(gr.dosnap)
end

if httpd == nil then
httpd = {}
end
if httpd.port == nil then
	httpd.port = 10888
end

CRLF = "\x0d\x0a"

function httpd.reply(sock,status,body,headers)
	if body == nil then body = '' end
	if headers == nil then headers = {} end
	if headers['content-type'] == nil then headers['content-type'] = 'text/html' end
	if headers['content-length'] == nil then headers['content-length'] = #body end
	if headers['connection'] == nil then headers['connection'] = 'close' end
	
	local reply = "HTTP/1.0 " .. tostring(status) .. CRLF
	for k,v in pairs(headers) do
		reply = reply .. k .. ': ' .. v .. CRLF
	end
	reply = reply .. CRLF .. body
	print("send reply of length ",#reply)
	sock:send(reply);
	sock:close();
end

if (url == nil) then url = {} end

function url_decode(x)
	if x == nil then return '' end
	local v = string.gsub(x,'%+',' ')
	v = string.gsub(v, '%%(%x%x)', function(s) return string.char( tonumber("0x"..s) ) end)
	return v
end

function url.parse(url)
	local qpos = string.find(url, "?");
	local path
	local query = {};
	if qpos ~= nil then
		path = string.sub(url,0,qpos-1)
		local qv = string.sub(url,qpos+1)
		for k,v in string.gmatch(qv,'([^&=]+)=([^&]*)') do
			k = url_decode(k)
			v = url_decode(v)
			query[ k ] = v
		end
	else
		path = url
	end
	return path,query
end

function httpd.worker(sock,host,port)
	box.fiber.detach()
	box.fiber.name("httpd.worker."..host..":"..port)
	-- print("worker");
	local line = sock:readline()
	if (line == nil or line == '') then return sock:close() end
	local meth, path, version = string.match(line, '^(%u+)%s([^%s]+)%sHTTP/([%d.]+)')
	if (meth == nil) then return sock:close() end
	local headers = {}
	while true do
		local line = sock:readline()
		if (line == nil or line == '') then return sock:close() end
		if (line == '\x0a' or line == '\x0d\x0a') then break end
		local k,v = string.match(line,'^([^%s]+)%s*:%s*([^\x0d\x0a]*)\x0d?\x0a')
		if (k == nil) then
			print("not parsed ", line)
		else
			k = string.lower(k)
			if headers[k] ~= nil then
				headers[k] = headers[k] .. '; ' .. v
			else
				headers[k] = v
			end
		end
	end
	
	print(meth,' ',path,' ('..headers['host']..')');
	local url, query = url.parse(path)
	-- print("resulting path ",url)
	--for k,v in pairs(query) do
	--	print(k,'=',v)
	--end
	
	local hdr = {}
	if (url == '/') then
		if query.from == nil then
			return httpd.reply(sock, 400, "from required");
		end
		
		local points = gr.points(query.target, os.time() - gr.st1t(query.from))
		-- hdr['content-type'] = 'application/x-json'
		hdr['content-type'] = 'text/plain'
		return httpd.reply(sock, 200, points, hdr);
	elseif url == '/metrics/find/' then
		
		hdr['content-type'] = 'application/json'
		local start = box.time();
		local info = gr.find(query.query)
		-- info = '[]'
		print("metric info in ",box.time() - start)
		return httpd.reply(sock, 200, info , hdr)
	elseif url == '/render/' then
		-- start, step, end, name, values: []
		
		hdr['content-type'] = 'application/json'
		local start = box.time();
		local data = gr.points(query.target, query.from, query['until']);
		print("data fetch in ",box.time() - start)
		
		return httpd.reply(sock, 200, data, hdr)
	else
		return httpd.reply(sock, 404, "Not found");
	end
	
	
	sock:close()
end

function httpd.server()
	box.fiber.detach()
	box.fiber.name("httpd.server")
	while true do
		local sock, status, host, port = httpd.sock:accept()
		if (status == nil) then
			print ("http accepted ",sock,'; ',host,":",port);
			local wfiber = box.fiber.create(httpd.worker)
			box.fiber.resume(wfiber, sock,host,port)
		else
			print ("http accept failed ", sock, status, host, port);
		end
		
	end
end


if httpd.sock == nil then
	local sock = box.socket.tcp()
	local s,status = sock:bind('0.0.0.0', httpd.port, 1);
	if status ~= nil then error(tostring(sock) .. ' ' .. s .. ' listen failed: ' .. status) end
	s,status = sock:listen()
	if status ~= nil then error(tostring(sock) .. ' ' .. s .. ' listen failed: ' .. status) end
	print("bound to http port ",httpd.port)
	httpd.sock = sock;
	local f = box.fiber.create(httpd.server)
	box.fiber.resume(f)
	
end

