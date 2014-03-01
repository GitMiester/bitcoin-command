config = require('config')
async = require('async')
url = require('url')
moment = require('moment')
BitcoinClient = require('bitcoin').Client
os = require('os')
request = require('request-json')

db = require('./db')
numTxt = require('./numberText')
io = require('./io')
_ = require('./underscore-plus')

anonymousChartCache = null
anonymousExpiration = 0
authenticatedChartCache = null
authenticatedExpiration = 0

getDeviceData = (cuttoff, callback) ->
	pipeline = [
		{
			$match:
				timestamp: $gte: cuttoff
		}
		{
			$sort: timestamp: 1
		}
		{
			$project:
				timestamp: 1
				hostname: 1
				device: 1
				pool: 1
				targetDifficulty: 1
				acceptedDifficulty: { $cond: [
					'$accepted'
					'$targetDifficulty'
					0
				]}
				rejectedDifficulty: { $cond: [
					'$accepted'
					0
					'$targetDifficulty'
				]}
		}
		{
			$group:
				_id:
					hostname: '$hostname'
					device: '$device'
				shares: $sum: '$targetDifficulty'
				accepted: $sum: '$acceptedDifficulty'
				rejected: $sum: '$rejectedDifficulty'
				lastPool: $last: '$pool'
				lastShare: $last: '$timestamp'
		}
		{
			$project:
				_id: 0
				hostname: '$_id.hostname'
				device: '$_id.device'
				hashrate: $multiply: [ '$shares', 0.397682157037037 ]
				shares: 1
				accepted: 1
				rejected: 1
				lastPool: 1
				lastShare: 1
		}
	]
	db.shares.aggregate(pipeline, callback)

updateMobileMiner = ->
	mm = config.mobileMiner
	return unless mm? and mm.apiKey? and mm.applicationKey and mm.email
	console.log 'Updating MobileMiner.'
	cuttoff = moment().subtract('hours', 1).unix()
	getDeviceData cuttoff, (err, data) ->
		baseUrl = "https://mobileminer.azurewebsites.net"
		client = request.newClient baseUrl
		hosts = _.chain(data).sortBy((item) -> item.id).groupBy('hostname').value()
		now = moment().unix()
		for host, devices of hosts
			path = "/api/MiningStatisticsInput?emailAddress=#{mm.email}&applicationKey=#{mm.applicationKey}&machineName=#{host}&apiKey=#{mm.apiKey}"
			console.log baseUrl, path
			data = []
			for device in devices
				status = "Alive"
				enabled = true
				if now - device.lastShare > 300
					status = "Offline"
					enabled = false
				else if device.shares > 0 and (device.rejected / device.shares > 0.1)
					status = "High Reject Rate"
				else if device.hashrate < 100
					status = "Low Hashrate"
				data.push {
					MinerName: 'BitcoinCommand'
					CoinSymbol: 'BTC'
					CoinName: 'Bitcoin'
					Algorithm: 'SHA-256'
					Name: device.device
					Kind: device.device
					FullName: device.type
					Status: status
					Enabled: enabled
					AverageHashrate: device.hashrate * 1000
					CurrentHashrate: device.hashrate * 1000
					AcceptedShares: device.accepted
					RejectedShares: device.rejected
					RejectedSharesPercent: 100 * device.rejected / device.shares
					HardwareErrorsPercent: 0
					HardwareErrors: 0

				}
			console.log data
			client.post path, data, (err, res, body) ->
				console.log res.statusCode
				console.log body

	return

exports.initialize = ->
	setInterval updateMobileMiner, 30000
	updateMobileMiner()

exports.submitshare = (req, res) ->
	unless req.query.key is config.submitShareKey
		res.statusCode = 401
		res.send('Unauthorized')
		return

	body = req.body
	unless body.hasOwnProperty('hostname') and body.hasOwnProperty('device') and body.hasOwnProperty('pool') and body.hasOwnProperty('result') and body.hasOwnProperty('shareHash') and body.hasOwnProperty('timestamp') and body.hasOwnProperty('targetDifficulty')
		res.statusCode = 400
		console.log "Invalid Share."
		return res.send('Invalid share object')

	# save the share
	share = {
		timestamp: body.timestamp
		shareHash: body.shareHash
		hostname: body.hostname.toLowerCase()
		device: body.device.toLowerCase()
		pool: body.pool.toLowerCase()
		accepted: body.result is 'accept'
		targetDifficulty: body.targetDifficulty
		shareDifficulty: body.shareDifficulty
	}

	db.shares.update { shareHash: share.shareHash }, share, { upsert: true }

	# create the worker if it doesn't exist

	prefix = share.device.match(/^\D+/)
	prefix = prefix[0] if prefix?
	prefix = prefix or ''
	type = switch prefix
		when 'amu' then 'ASICMiner USB'
		when 'bas' then 'BFL Single SC'
		when 'baj' then 'BFL Jalapeno'
		when 'bitfury' then 'BitFury'
		else 'Unknown'
	device = {
		hostname: share.hostname
		device: share.device
		type: type
	}
	db.devices.update { hostname: device.hostname, device: device.device}, {$setOnInsert: device}, { upsert: true }

	# create the pool if it doesn't exist
	pool = {
		name: url.parse(share.pool).hostname
		url: share.pool
		enabled: true
	}
	db.pools.update {url: pool.url}, {$setOnInsert: pool}, { upsert: true }

	db.pools.findOne {url: pool.url}, (err, pool) ->
		msg = {
			hostname: share.hostname
			device: share.device
			pool: pool.name
		}
		io.http.sockets.emit('share', msg)
		io.https.sockets.emit('share', msg) if io.https?
	res.json result: true

exports.summarydata = (req, res) ->
	cuttoff = moment().subtract('hours', 1).unix()
	client = new BitcoinClient config.bitcoin

	async.parallel({
		difficulty: (callback) ->
			client.getDifficulty callback
		poolInfo: (callback) ->
			db.pools.find().toArray(callback)
		deviceInfo: (callback) ->
			db.devices.find().toArray(callback)
		devices: (callback) ->
			getDeviceData cuttoff, callback
		pools: (callback) ->
			pipeline = [
				{
					$match:
						timestamp: $gte: cuttoff
				}
				{
					$sort: timestamp: 1
				}
				{
					$project:
						timestamp: 1
						pool: 1
						targetDifficulty: 1
						acceptedDifficulty: { $cond: [
							'$accepted'
							'$targetDifficulty'
							0
						]}
						rejectedDifficulty: { $cond: [
							'$accepted'
							0
							'$targetDifficulty'
						]}
				}
				{
					$group:
						_id: '$pool'
						shares: $sum: '$targetDifficulty'
						accepted: $sum: '$acceptedDifficulty'
						rejected: $sum: '$rejectedDifficulty'
						lastShare: $last: '$timestamp'
				}
				{
					$project:
						_id: 0
						url: '$_id'
						hashrate: $multiply: [ '$shares', 0.397682157037037 ] # $shares * 2^32 / (3600 * 3) / 1000000
						shares: 1
						accepted: 1
						rejected: 1
						lastShare: 1
				}
			]
			db.shares.aggregate(pipeline, callback)
	}, (err, results) ->

		if err
			return res.json err

		results.poolInfo = _.filter results.poolInfo, (item) -> item.enabled
		results.poolInfo = _.sortBy results.poolInfo, (item) -> item.name

		unless req.authenticated
			counter = 1
			p.name = "pool #{numTxt.numberToText(counter++)}" for p in results.poolInfo

		poolInfo = _.toDictionary results.poolInfo, 'url'
		deviceInfo = _.toDictionary results.deviceInfo, (d) -> "#{d.hostname}:#{d.device}"

		# filter out any pool stats for disabled pools
		results.pools = _.filter results.pools, (pool) -> poolInfo[pool.url]

		data = {}

		data.totalHashrate = Number(_.reduce(results.devices, (sum, device) ->
			sum + device.hashrate
		, 0).toFixed(0))

		data.expectedRate = (25 / results.difficulty) * 86400 * (data.totalHashrate * 1000000 / 4294967296 ) * 0.97
		data.expectedRate = Number(data.expectedRate.toFixed(4))

		for pool in results.pools
			pool.name = poolInfo[pool.url].name
			pool.payouts = poolInfo[pool.url].payouts
			pool.pending = poolInfo[pool.url].pending
			pool.poolSize = poolInfo[pool.url].poolSize
			delete pool.url
		data.pools = _.sortBy results.pools, (item) -> item.name

		for device in results.devices
			id = "#{device.hostname}:#{device.device}"
			device.lastPool = poolInfo[device.lastPool]?.name || ''
			device.id = id
			device.type = deviceInfo[id].type
			device.status = deviceInfo[id].status
			device.errors = deviceInfo[id].errors
			device.temp = deviceInfo[id].temp
		data.devices = _.chain(results.devices).sortBy((item) -> item.id).groupBy('hostname').value()

		res.json data
	)
	return


exports.chartdata = (req, res) ->
	if req.authenticated and authenticatedChartCache? and moment().unix() < authenticatedExpiration
		res.json authenticatedChartCache
		return

	if !req.authenticated and anonymousChartCache and moment().unix() < anonymousExpiration
		res.json anonymousChartCache
		return

	end = moment().seconds(0).millisecond(0).subtract('minutes',1).unix()
	start = end - (3600 * 24 * 3) # 3 days

	histogram = {}

	db.pools.find(enabled: true).toArray (err, pools) ->
		if err then return res.json err

		pools = _.sortBy pools, (item) -> item.name
		unless req.authenticated
			counter = 1
			p.name = "pool #{numTxt.numberToText(counter++)}" for p in pools

		async.each(pools, (pool, callback) ->
			pipeline = [
				{
					$match: {
						pool: pool.url
						timestamp: { $gte: start, $lt: end }
					}
				}
				{
					$project: {
						timeslot: {
							$subtract: [
								'$timestamp'
								$mod : [
									$subtract: ['$timestamp', start]
									3600
								]
							]
						}
						targetDifficulty: 1
					}
				}
				{
					$group: {
						_id: '$timeslot'
						shares: { $sum: '$targetDifficulty' }
					}
				}
				{
					$project: {
						_id: 0
						timeslot: '$_id'
						hashrate: { $multiply: [ '$shares', 1.1930464711111111111111111111111 ] } # $shares * 2^32 / 3600 / 1000000
					}
				}
				{
					$sort: { timeslot: 1 }
				}
			]

			db.shares.aggregate pipeline, (err, results) ->
				if err
					callback(err)
					return

				buckets = histogram[pool.name] = {}
				buckets[entry.timeslot] = Number(entry.hashrate.toFixed(0)) for entry in results
				callback()

		, (err) ->
			if err
				res.json err
				return

			series = []
			for pool in pools
				name = pool.name
				data = []
				entry = name: name, data: data
				series.push entry
				i = start
				while i < end
					data.push histogram[name][i] || 0
					i += 3600

			result = {
				pointInterval: 3600000
				pointStart: start * 1000
				series: series
			}

			if req.authenticated
				authenticatedChartCache = result
				authenticatedExpiration = moment().add('minutes', 5).unix()
			else
				anonymousChartCache = result
				anonymousExpiration = moment().add('minutes', 5).unix()

			res.json result
		)
	return
