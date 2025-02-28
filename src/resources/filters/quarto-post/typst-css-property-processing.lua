local constants = require("modules/constants")

function format_typst_float(x)
  local f = string.format('%.2f', x)
  -- trim zeros after decimal point
  return f:gsub('%.00', ''):gsub('%.(%d)0', '.%1')
end

function render_typst_css_property_processing()
  if not _quarto.format.isTypstOutput() or
    param(constants.kCssPropertyProcessing, 'translate') ~= 'translate' then
    return {}
  end

  local function to_kv(prop_clause)
    return string.match(prop_clause, '([%w-]+)%s*:%s*(.*)$')
  end

  local _warnings
  local function new_table()
    local ret = {}
    setmetatable(ret, {__index = table})
    return ret
  end
  local function aggregate_warnings()
    local counts = {}
    for _, warning in ipairs(_warnings) do
      counts[warning] = (counts[warning] or 0) + 1
    end
    for warning, count in pairs(counts) do
      quarto.log.warning('(' .. string.format('%4d', count) .. ' times) ' .. warning)
    end
  end

  local function sortedPairs(t, f)
    local a = {}
    for n in pairs(t) do table.insert(a, n) end
    table.sort(a, f)
    local i = 0      -- iterator variable
    local iter = function()   -- iterator function
        i = i + 1
        if a[i] == nil then return nil
        else return a[i], t[a[i]]
        end
    end
    return iter
  end

  local function dequote(s)
    return s:gsub('^["\']', ''):gsub('["\']$', '')
  end

  local function quote(s)
    return '"' .. s .. '"'
  end

  local function translate_vertical_align(va)
    if va == 'top' then
      return 'top'
    elseif va == 'middle' then
      return 'horizon'
    elseif va == 'bottom' then
      return 'bottom'
    end
  end

  -- does the table contain a value
  local function tcontains(t,value)
    if t and type(t)=='table' and value then
      for _, v in ipairs(t) do
        if v == value then
          return true
        end
      end
      return false
    end
    return false
  end

  local function translate_horizontal_align(ha)
    if tcontains({'start', 'end', 'center'}, ha) then
      return ha
    end
    return nil
  end

  local function to_typst_dict(tab)
    local entries = {}
    for k, v in sortedPairs(tab) do
      if type(v) == 'table' then
        v = to_typst_dict(v)
      end
      if k and v then
        table.insert(entries, k .. ': ' .. v)
      end
    end
    if #entries == 0 then return nil end
    return '(' .. table.concat(entries, ', ') .. ')'
  end

  local border_sides = {'left', 'top', 'right', 'bottom'}
  local border_properties = {'width', 'style', 'color'}
  local border_width_keywords = {
    thin = '1px',
    medium = '3px',
    thick = '5px'
  }

  local function all_equal(seq)
    local a = seq[1]
    for i = 2, #seq do
      if a ~= seq[i] then
        return false
      end
    end
    return true
  end

  local function translate_border_width(v)
    v = border_width_keywords[v] or v
    local thickness = _quarto.format.typst.css.translate_length(v, _warnings)
    return thickness == '0pt' and 'delete' or thickness
  end

  local function translate_border_style(v)
    local dash
    if v == 'none' then
      return 'delete'
    elseif tcontains({'dotted', 'dashed'}, v) then
      return quote(v)
    end
    return nil
  end

  local function translate_border_color(v)
    return _quarto.format.typst.css.output_color(_quarto.modules.typst.css.parse_color(v, _warnings), nil, _warnings)
  end

  local border_translators = {
    width = {
      prop = 'thickness',
      fn = translate_border_width
    },
    style = {
      prop = 'dash',
      fn = translate_border_style
    },
    color = {
      prop = 'paint',
      fn = translate_border_color
    }
  }

  -- only a few of these map to typst, again seems simplest to parse anyway
  local border_styles = {
    'none', 'hidden', 'dotted', 'dashed', 'solid', 'double', 'groove', 'ridge', 'inset', 'outset', 'inherit', 'initial', 'revert', 'revert-layer', 'unset'
  }

  function parse_multiple(s, limit, callback)
    local start = 0
    local count = 0
    repeat
      start = callback(s, start)
      -- not really necessary with string:find
      -- as evidenced that s.sub also works
      while s:sub(start, start) == ' ' do
        start = start + 1
      end
      count = count + 1
    until count >=limit or start >= #s
  end

  -- border shorthand
  -- https://developer.mozilla.org/en-US/docs/Web/CSS/border
  local function translate_border(v)
    -- not sure why the default style that works is not the same one specified
    local width = 'medium'
    local style = 'solid' -- css specifies none
    local paint = 'black' -- css specifies currentcolor
    parse_multiple(v, 3, function(s, start)
      local fbeg, fend = s:find('%w+%b()', start)
      if fbeg then
        local paint2 = translate_border_color(s:sub(fbeg, fend))
        if paint2 then
          paint = paint2
        end
        return fend + 1
      else
        fbeg, fend = s:find('%S+', start)
        local term = v:sub(fbeg, fend)
        if tcontains(border_styles, term) then
          style = term
        else
          if _quarto.format.typst.css.parse_length_unit(term) or border_width_keywords[term] then
            width = term
          else
            local paint2 = translate_border_color(term)
            if paint2 then
              paint = paint2
            else
              _warnings:insert('invalid border shorthand ' .. term)
            end
          end
        end
        return fend + 1
      end
    end)
    return {
      thickness = translate_border_width(width),
      dash = translate_border_style(style),
      paint = paint
    }
  end

  local function consume_width(s, start)
      fbeg, fend = s:find('%S+', start)
      local term = s:sub(fbeg, fend)
      local thickness = translate_border_width(term)
      return thickness, fend + 1
  end

  local function consume_style(s, start)
    fbeg, fend = s:find('%S+', start)
    local term = s:sub(fbeg, fend)
    local dash = translate_border_style(term)
    return dash, fend + 1
  end

  local function consume_color(s, start)
    local fbeg, fend = s:find('%w+%b()', start)
    if not fbeg then
      fbeg, fend = s:find('%S+', start)
    end
    if not fbeg then return nil end
    local paint = translate_border_color(s:sub(fbeg, fend))
    return paint, fend + 1
  end

  local border_consumers = {
    width = consume_width,
    style = consume_style,
    color = consume_color,
  }
  local function handle_border(k, v, borders)
    local _, ndash = k:gsub('-', '')
    if ndash == 0 then
      local border = translate_border(v)
      for _, side in ipairs(border_sides) do
        borders[side] = borders[side] or {}
        for k2, v2 in pairs(border) do
          borders[side][k2] = v2
        end
      end
    elseif ndash == 1 then
      local part = k:match('^border--(%a+)')
      if tcontains(border_sides, part) then
        borders[part] = borders[part] or {}
        local border = translate_border(v)
        for k2, v2 in pairs(border) do
          borders[part][k2] = v2
        end
      elseif tcontains(border_properties, part) then
        local items = {}
        parse_multiple(v, 4, function(s, start)
          local item, newstart = border_consumers[part](s, start)
          table.insert(items, item)
          return newstart
        end)
        for _, side in ipairs(border_sides) do
          borders[side] = borders[side] or {}
        end
        local xlate = border_translators[part]
        if #items == 0 then
          _warnings:insert('no valid ' .. part .. 's in ' .. v)
        -- the most css thing ever
        elseif #items == 1 then
          borders.top[xlate.prop] = items[1]
          borders.right[xlate.prop] = items[1]
          borders.bottom[xlate.prop] = items[1]
          borders.left[xlate.prop] = items[1]
        elseif #items == 2 then
          borders.top[xlate.prop] = items[1]
          borders.right[xlate.prop] = items[2]
          borders.bottom[xlate.prop] = items[1]
          borders.left[xlate.prop] = items[2]
        elseif #items == 3 then
          borders.top[xlate.prop] = items[1]
          borders.right[xlate.prop] = items[2]
          borders.bottom[xlate.prop] = items[3]
          borders.left[xlate.prop] = items[2]
        elseif #items == 4 then
          borders.top[xlate.prop] = items[1]
          borders.right[xlate.prop] = items[2]
          borders.bottom[xlate.prop] = items[3]
          borders.left[xlate.prop] = items[4]
        else
          _warnings:insert('too many values in ' .. k .. ' list: ' .. v)
        end
      else
        _warnings:insert('invalid 2-item border key ' .. k)
      end
    elseif ndash == 2 then
      local side, prop = k:match('^border--(%a+)--(%a+)')
      if tcontains(border_sides, side) and tcontains(border_properties, prop) then
        borders[side] = borders[side] or {}
        local tr = border_translators[prop]
        borders[side][tr.prop] = tr.fn(v)
      else
        _warnings:insert('invalid 3-item border key ' .. k)
      end
    else
      _warnings:insert('invalid too-many-item key ' .. k)
    end
  end

  local function annotate_cell(cell)
    local style = cell.attributes['style']
    if style ~= nil then
      local paddings = {}
      local aligns = {}
      local borders = {}
      local color = nil
      local opacity = nil
      for clause in style:gmatch('([^;]+)') do
        local k, v = to_kv(clause)
        if not k or not v then
          -- pass
        elseif k == 'background-color' then
          cell.attributes['typst:fill'] = _quarto.format.typst.css.output_color(_quarto.format.typst.css.parse_color(v, _warnings), nil, _warnings)
        elseif k == 'color' then
          color = _quarto.format.typst.css.parse_color(v, _warnings)
        elseif k == 'opacity' then
          opacity = _quarto.format.typst.css.parse_opacity(v, _warnings)
        elseif k == 'font-size' then
          cell.attributes['typst:text:size'] = _quarto.format.typst.css.translate_length(v, _warnings)
        elseif k == 'vertical-align' then
          local a = translate_vertical_align(v)
          if a then table.insert(aligns, a) end
        elseif k == 'text-align' then
          local a = translate_horizontal_align(v)
          if a then table.insert(aligns, a) end
        -- elseif k:find '^padding--' then
        --   paddings[k:match('^padding--(%a+)')] = _quarto.format.typst.css.translate_length(v, _warnings)
        elseif k:find '^border' then
          handle_border(k, v, borders)
        end
      end
      if next(aligns) ~= nil then
        cell.attributes['typst:align'] = table.concat(aligns, ' + ')
      end
      if color or opacity then
        cell.attributes['typst:text:fill'] = _quarto.format.typst.css.output_color(color, opacity, _warnings)
      end

      -- inset seems either buggy or hard to get right, see
      -- https://github.com/quarto-dev/quarto-cli/pull/9387#issuecomment-2076015962
      -- if next(paddings) ~= nil then
      --   cell.attributes['typst:inset'] = to_typst_dict(paddings)
      -- end

      -- since e.g. the left side of one cell can override the right side of another
      -- we do not specify sides that have width=0 or style=none
      -- this assumes an additive model - currently no way to start with all lines
      -- and remove some
      local delsides = {}
      for side, attrs in pairs(borders) do
        if attrs.thickness == 'delete' or attrs.dash == 'delete' then
          table.insert(delsides, side)
        end
      end
      for _, dside in pairs(delsides) do
        borders[dside] = nil
      end
      if next(borders) ~= nil then
        -- if all are the same, use one stroke and don't split by side
        local thicknesses = {}
        local dashes = {}
        local paints = {}
        for _, side in ipairs(border_sides) do
          table.insert(thicknesses, borders[side] and borders[side].thickness or 0)
          table.insert(dashes, borders[side] and borders[side].dash or 0)
          table.insert(paints, borders[side] and borders[side].paint or 0)
        end
        quarto.log.debug('thicknesses', table.unpack(thicknesses))
        quarto.log.debug('dashes', table.unpack(dashes))
        quarto.log.debug('paints', table.unpack(paints))
        if all_equal(thicknesses) and all_equal(dashes) and all_equal(paints) then
          assert(borders.left)
          cell.attributes['typst:stroke'] = to_typst_dict(borders.left)
        else
          cell.attributes['typst:stroke'] = to_typst_dict(borders)
        end
      end
    end
    return cell
  end

  function annotate_span(span)
    span = annotate_cell(span) -- not really
    local style = span.attributes['style']
    local hlprops = {}
    if style ~= nil then
      for clause in style:gmatch('([^;]+)') do
        local k, v = to_kv(clause)
        if k == 'background-color' then
          hlprops.fill = _quarto.format.typst.css.output_color(_quarto.format.typst.css.parse_color(v, _warnings), nil, _warnings)
        end
      end
    end
    -- span borders can be added to #highlight() but it doesn't look good out of the box
    -- see https://github.com/quarto-dev/quarto-cli/pull/9619#issuecomment-2101936530
    -- if span.attributes['typst:stroke'] then
    --   hlprops.stroke = span.attributes['typst:stroke']
    --   span.attributes['typst:stroke'] = nil
    -- end
    if next(hlprops) ~= nil then
      if not hlprops.fill then
        hlprops.fill = 'rgb(0,0,0,0)'
      end
      return pandoc.Inlines({
        pandoc.RawInline('typst', '#highlight' .. to_typst_dict(hlprops) .. '['),
        span,
        pandoc.RawInline('typst', ']')
      })
    end
    return span
  end

  local function translate_string_list(sl)
    local strings = {}
    for s in sl:gmatch('([^,]+)') do
      s = s:gsub('^%s+', '')
      table.insert(strings, quote(dequote(s)))
    end
    return '(' .. table.concat(strings, ', ') ..')'
  end
  
  return {
    Table = function(tab)
      _warnings = new_table()
      local tabstyle = tab.attributes['style']
      if tabstyle ~= nil then
        for clause in tabstyle:gmatch('([^;]+)') do
          local k, v = to_kv(clause)
          if k == 'font-family' then
            tab.attributes['typst:text:font'] = translate_string_list(v)
          end
          if k == 'font-size' then
            tab.attributes['typst:text:size'] = _quarto.format.typst.css.translate_length(v, _warnings)
          end
        end
      end
      if tab.head then
        for _, row in ipairs(tab.head.rows) do
          for _, cell in ipairs(row.cells) do
            annotate_cell(cell)
          end
        end
      end
      for _, body in ipairs(tab.bodies) do
        for _, row in ipairs(body.body) do
          for _, cell in ipairs(row.cells) do
            annotate_cell(cell)
          end
        end
      end
      aggregate_warnings()
      _warnings = nil
      return tab
    end,
    Div = function(div)
      _warnings = new_table()
      local divstyle = div.attributes['style']
      if divstyle ~= nil then
        for clause in divstyle:gmatch('([^;]+)') do
          local k, v = to_kv(clause)
          if k == 'font-family' then
            div.attributes['typst:text:font'] = translate_string_list(v)
          end
          if k == 'font-size' then
            div.attributes['typst:text:size'] = _quarto.format.typst.css.translate_length(v, _warnings)
          end
        end
      end
      aggregate_warnings()
      _warnings = nil
      return div
    end,
    Span = function(span)
      _warnings = new_table()
      span = annotate_span(span)
      aggregate_warnings()
      _warnings = nil
      return span
    end
  }
end