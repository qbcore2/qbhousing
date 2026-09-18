fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbhousing'
author 'qbcore2'
description 'Server-authoritative QBCore housing and real-estate listings'
version '1.0.0'

dependency 'qblib'
dependency 'qbsql'
dependency 'qbcore'
dependency 'qbinterior'
dependency 'qbtarget'
dependency 'qbbanking'

shared_scripts {
    '@qblib/init.lua',
    '@qbsql/init.lua',
    '@qbcore/init.lua',
    'config.lua',
    'shared/schema.lua',
}

server_scripts {
    'server/state.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

files { 'sql/001_housing.sql' }
