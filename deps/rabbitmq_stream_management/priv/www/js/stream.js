dispatcher_add(function(sammy) {
    sammy.get('#/stream-connections', function() {
            renderStreamConnections();
        });

});

NAVIGATION['Stream'] = ['#/stream-connections', "monitoring"];

var ALL_STREAM_COLUMNS =
     {'Overview': [['user',   'User name', true],
                   ['state',  'State',     true]],
      'Details': [['protocol',       'Protocol',       true],
                  ['frame_max',      'Frame max',      false],
                  ['auth_mechanism', 'Auth mechanism', false],
                  ['client',         'Client',         false]],
      'Network': [['from_client',  'From client',  true],
                  ['to_client',    'To client',    true],
                  ['heartbeat',    'Heartbeat',    false],
                  ['connected_at', 'Connected at', false]]};

var DISABLED_STATS_STREAM_COLUMNS =
     {'Overview': [['user',   'User name', true],
                   ['state',  'State',     true]]};

COLUMNS['streamConnections'] = disable_stats?DISABLED_STATS_STREAM_COLUMNS:ALL_STREAM_COLUMNS;

function renderStreamConnections() {
  render({'connections': {path: url_pagination_template_context('stream-connections', 'streamConnections', 1, 5),
                          options: {sort:true}}},
                          'streamConnections', '#/stream-connections');
}

RENDER_CALLBACKS['streamConnections'] = function() { renderStreamConnections() };