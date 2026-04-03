#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2026 ImmortalWrt.org
 */

'use strict';

import { open } from 'fs';
import { connect as socket_connect } from 'socket';
import { cursor } from 'uci';

import { urlencode } from 'luci.http';

import {
	executeCommand, getTime, isEmpty, parseURL, RUN_DIR
} from 'homeproxy';

const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const ucimain = 'config',
      uciroutingnode = 'routing_node';

const DEFAULT_PROBE_URL = 'https://www.gstatic.com/generate_204';
const DEFAULT_PROBE_INTERVAL = 30;
const DEFAULT_PROBE_TIMEOUT = 5000;
const CLASH_API_HOST = '127.0.0.1';
const CLASH_API_PORT = 5334;

function log(...args) {
	const logfile = open(`${RUN_DIR}/homeproxy.log`, 'a');
	logfile.write(`${getTime()} [FALLBACK] ${join(' ', args)}\n`);
	logfile.close();
}

function current_time() {
	const output = executeCommand('/bin/date', '+%s') || {};
	return int(trim(output.stdout)) || 0;
}

function parse_positive_int(value, default_value) {
	value = int(value);
	return value > 0 ? value : default_value;
}

function normalize_nodes(nodes) {
	if (isEmpty(nodes))
		return [];
	else if (type(nodes) === 'array')
		return map(filter(nodes, (v) => !isEmpty(v)), (v) => `cfg-${v}-out`);
	else
		return [`cfg-${nodes}-out`];
}

function normalize_probe_url(url) {
	if (type(url) !== 'string' || isEmpty(trim(url)))
		return DEFAULT_PROBE_URL;

	url = trim(url);
	return parseURL(url) ? url : DEFAULT_PROBE_URL;
}

function build_group(selector_tag, nodes, probe_url, probe_interval, probe_timeout) {
	nodes = normalize_nodes(nodes);
	if (isEmpty(nodes)) {
		log(sprintf('Skipping selector %s because fallback nodes are empty.', selector_tag));
		return null;
	}

	return {
		selector_tag: selector_tag,
		nodes: nodes,
		url: normalize_probe_url(probe_url),
		interval: parse_positive_int(probe_interval, DEFAULT_PROBE_INTERVAL),
		timeout: parse_positive_int(probe_timeout, DEFAULT_PROBE_TIMEOUT),
		next_due: 0
	};
}

function is_success(res) {
	return res?.status >= 200 && res.status < 300;
}

function clash_request(method, path, timeout, body) {
	let payload = !isEmpty(body) ? sprintf('%.J', body) : '';
	let request = [
		sprintf('%s %s HTTP/1.1', method || 'GET', path),
		sprintf('Host: %s', CLASH_API_HOST),
		'Connection: close'
	];

	if (!isEmpty(payload)) {
		push(request, 'Content-Type: application/json');
		push(request, sprintf('Content-Length: %d', length(payload)));
	}

	request = join('\r\n', request) + '\r\n\r\n' + payload;

	let sock = socket_connect(
		CLASH_API_HOST,
		CLASH_API_PORT,
		{},
		parse_positive_int(timeout, DEFAULT_PROBE_TIMEOUT)
	);
	if (!sock)
		return null;

	if (!sock.send(request)) {
		sock.close();
		return null;
	}

	let response = '', chunk;
	while ((chunk = sock.recv(1024)) != null) {
		if (chunk === '')
			break;

		response += chunk;
	}

	sock.close();

	let status = match(response, /^HTTP\/1\.[01]\s+(\d+)/);
	let body_text = split(response, '\r\n\r\n')[1];

	return {
		status: status ? int(status[1]) : null,
		body: body_text || ''
	};
}

function wait_controller() {
	for (let retry = 0; retry < 30; retry++) {
		const res = clash_request('GET', '/proxies', DEFAULT_PROBE_TIMEOUT);
		if (is_success(res))
			return true;

		system('sleep 1');
	}

	log('Clash API is not reachable, stopping fallback watchdog.');
	return false;
}

function get_selector_state(selector_tag, timeout) {
	const res = clash_request('GET', '/proxies/' + urlencode(selector_tag), timeout);
	if (!is_success(res) || isEmpty(trim(res.body)))
		return null;

	return json(trim(res.body));
}

function probe_node(node_tag, group) {
	const res = clash_request(
		'GET',
		sprintf('/proxies/%s/delay?timeout=%d&url=%s',
			urlencode(node_tag), group.timeout, urlencode(group.url)
		),
		group.timeout
	);
	if (!is_success(res) || isEmpty(trim(res.body)))
		return false;

	return json(trim(res.body))?.delay != null;
}

function switch_selector(group, node_tag) {
	const res = clash_request(
		'PUT',
		'/proxies/' + urlencode(group.selector_tag),
		group.timeout,
		{ name: node_tag }
	);

	return is_success(res);
}

function check_group(group) {
	const selector = get_selector_state(group.selector_tag, group.timeout);
	if (isEmpty(selector)) {
		log(sprintf('Failed to query selector %s from Clash API.', group.selector_tag));
		return;
	}

	const current = selector.now;
	const current_index = index(group.nodes, current);
	if (~current_index && probe_node(current, group))
		return;

	let candidates = [];
	if (~current_index) {
		for (let i = current_index + 1; i < length(group.nodes); i++)
			push(candidates, group.nodes[i]);
		for (let i = 0; i < current_index; i++)
			push(candidates, group.nodes[i]);
	} else
		candidates = group.nodes;

	for (let node in candidates) {
		if (!probe_node(node, group))
			continue;

		if (switch_selector(group, node)) {
			log(sprintf('Selector %s switched to %s.', group.selector_tag, node));
			return;
		}

		log(sprintf('Selector %s failed to switch to %s.', group.selector_tag, node));
		return;
	}

	log(sprintf('Selector %s has no healthy fallback node, keeping %s.', group.selector_tag, current || 'current selection'));
}

function load_groups() {
	const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';
	let groups = [];

	if (routing_mode !== 'custom') {
		const main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
		const main_udp_node = uci.get(uciconfig, ucimain, 'main_udp_node') || 'nil';

		if (main_node === 'fallback') {
			const group = build_group(
				'main-out',
				uci.get(uciconfig, ucimain, 'main_fallback_nodes'),
				uci.get(uciconfig, ucimain, 'main_fallback_url'),
				uci.get(uciconfig, ucimain, 'main_fallback_interval'),
				DEFAULT_PROBE_TIMEOUT
			);
			if (group)
				push(groups, group);
		}

		if (main_udp_node === 'fallback') {
			const group = build_group(
				'main-udp-out',
				uci.get(uciconfig, ucimain, 'main_udp_fallback_nodes'),
				uci.get(uciconfig, ucimain, 'main_udp_fallback_url'),
				uci.get(uciconfig, ucimain, 'main_udp_fallback_interval'),
				DEFAULT_PROBE_TIMEOUT
			);
			if (group)
				push(groups, group);
		}
	} else {
		uci.foreach(uciconfig, uciroutingnode, (cfg) => {
			if (cfg.enabled !== '1' || cfg.node !== 'fallback')
				return;

			const group = build_group(
				'cfg-' + cfg['.name'] + '-out',
				cfg.fallback_nodes,
				cfg.fallback_url,
				cfg.fallback_interval,
				cfg.fallback_timeout
			);
			if (group)
				push(groups, group);
		});
	}

	return groups;
}

function main() {
	const groups = load_groups();
	if (isEmpty(groups)) {
		log('No fallback group found, stopping fallback watchdog.');
		return null;
	}

	if (!wait_controller())
		die('Clash API is unreachable.');

	log(sprintf('Fallback watchdog started for %s selector(s).', length(groups)));

	let now = current_time();
	for (let i = 0; i < length(groups); i++)
		groups[i].next_due = now;

	while (true) {
		now = current_time();

		let sleep_for = null;
		for (let i = 0; i < length(groups); i++) {
			if (groups[i].next_due > now) {
				const wait = groups[i].next_due - now;
				if (!sleep_for || wait < sleep_for)
					sleep_for = wait;
				continue;
			}

			check_group(groups[i]);
			groups[i].next_due = current_time() + groups[i].interval;
			if (!sleep_for || groups[i].interval < sleep_for)
				sleep_for = groups[i].interval;
		}

		system(sprintf('sleep %d', sleep_for || 1));
	}
}

try {
	call(main);
} catch(e) {
	log('[FATAL ERROR] An error occurred in fallback watchdog:');
	log(sprintf('%s: %s', e.type, e.message));
	log(e.stacktrace[0].context);

	die(e.message);
}
