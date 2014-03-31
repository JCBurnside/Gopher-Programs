local component=require("component")

local colorutils=require("colorutils")

local buffer={}
local bufferMeta={}

local debugPrint=function() end

--copy these to file local, they're called a lot in performance-intensive loops
local convColor_hto8=colorutils.convColor_hto8
local convColor_8toh=colorutils.convColor_8toh


local function encodeColor(fg,bg)
  return convColor_hto8(bg)*256+convColor_hto8(fg)
end

local function decodeColor(c)
  return convColor_8toh(math.floor(c/256)),convColor_8toh(c%256)
end



function bufferMeta.getBackground(buffer)
  return convColor_8toh(buffer.colorBackground)
end

function bufferMeta.setBackground(buffer,color)
  local p=buffer.colorBackground
  buffer.colorBackground=color
  buffer.color=encodeColor(buffer.colorForeground,color)
  return p
end

function bufferMeta.getForeground(buffer)
  return buffer.colorForeground
end

function bufferMeta.setForeground(buffer,color)
  local p=buffer.colorForeground
  buffer.colorForeground=color
  buffer.color=encodeColor(color,buffer.colorBackground)
  return p
end


function bufferMeta.buffer_get(buffer,x,y)
  buffer.flush()
  return parent.get(x,y)
end

function bufferMeta.copy(buffer,x,y,w,h,dx,dy)
  buffer.flush()
  return parent.copy(x,y,w,h,dx,dy)
end

function bufferMeta.fill(buffer,x,y,w,h,char)
  buffer.flush()
  return parent.fill(x,y,w,h,char)
end


function bufferMeta.set(buffer,x,y,str)
  local spans=buffer.spans

  local spanI=1
  local color=buffer.color
  local e=x+#str-1

  while spans[spanI] and (spans[spanI].y<y or spans[spanI].y==y and spans[spanI].e<x) do
    spanI=spanI+1
  end
  --ok, now spanI is either intersecting me or the first after me
  --if intersect, crop

  if not spans[spanI] then
    debugPrint("just inserting at "..spanI)
    span={str=str,e=e,x=x,y=y,color=color}
    spans[spanI]=span
  else
    debugPrint("scanned to span "..spanI)
    if span.y==y and span.x<e then
      debugPrint("it starts before I end.")
      --it starts before me. Can I merge with it?
      if span.color==color then
        --we can merge. Yay.
        --splice myself in
        debugPrint("splicing at "..math.max(0,(x-span.x)))
        local a,c=span.str:sub(1,math.max(0,x-span.x)), span.str:sub(e-span.x+2)
        debugPrint("before=\""..a.."\", after=\""..c..'"')
        span.str=a..str..c
        --correct x and e(nd)
        if x<span.x then
          span.x=x
        end
        if e > span.e then
          span.e=e
        end
      else
        --can't, gonna have to make a new span
        --but first, split this guy as needed
        debugPrint("can't merge. Splitting")
        local a,b=span.str:sub(1,math.max(0,x-span.x)),span.str:sub(e-span.x+2)
        if #a>0 then
          span.str=a
          span.e=span.x+#a
          --span is a new span
          span={str=true,e=true,x=true,y=y,color=span.color}
          --insert after this span
          spanI=spanI+1
          table.insert(spans,spanI,span)
        end
        if #b>0 then
          span.str=b
          span.x=e+1
          span.e=span.x+#b

          --and another new span
          span={str=true,e=true,x=true,y=y,color=color}
          --insert /before/ this one
          table.insert(spans,spanI,span)
        end
        --now make whatever span we're left with me.
        span.color=color
        span.x, span.e = x, e
        span.str=str
        span.y=y
      end
    else
      --starts inside or after me. tf, missed whole case.
    end
    --ok. We are span. We are at spanI. We've inserted ourselves. Now just check if we've obliterated anyone.
    --while the next span starts before I end...
    spanI=spanI+1
    while spans[spanI] and spans[spanI].y==y and spans[spanI].x<=e do
      span=spans[spanI]
      if span.e>e then
        --it goes past me, we just circumcise it
        span.str=span.str:sub(e-span.x+2)
        span.x=e+1
        break--and there can't be more
      end
      --doesn't end after us, means we obliterated it
      table.remove(spans,spanI)
      --spanI will now point to the next, if any
    end
  end

  --[[this..won't work. Was forgetting I have a table per row, this would count rows.
  if #spans>=buffer.autoFlushCount then
    buffer.flush()
  end
  --]]
end


function bufferMeta.flush(buffer)
  debugPrint("flush?")
  --sort by colors. bg is added as high value, so this will group all with common bg together,
  --and all with common fg together within same bg.
  table.sort(buffer.spans,
      function(spanA,spanB)
        return spanA.color<spanB.color
      end )

  --now draw the spans!
  local parent=buffer.parent
  local pfg,pbg=parent.getForeground(), parent.getBackground()
  local cfg,cbg=pfg,pbg
  local spans=buffer.spans

  for i=1,#spans do
    local span=spans[i]
    local bg,fg=decodeColor(span.color)
    if fg~=cfg then
      parent.setForeground(fg)
      cfg=fg
    end
    if bg~=cbg then
      parent.setBackground(bg)
      cbg=bg
    end
    parent.set(span.x,span.y,span.str)
  end
  if cfg~=pfg then
    parent.setForeground(pfg)
  end
  if cbg~=pbg then
    parent.setBackground(pbg)
  end
  --...and that's that. Throw away our spans.
  buffer.spans={}
  --might have to experiment later, see if the cost of rebuilding (and re-growing) the table is offset
  --by the savings of not having the underlying spans object grow based on peak buffer usage,
  --but if I'm optimizing for memory (and I am, in this case), then this seems a safe call for now.
  --If it ends up an issue, might be able to offset the computational cost by initing to an array of some average size, then
  --niling the elements in a loop.

end

function buffer.create(parent)
  parent=parent or component.gpu
  local width,height=parent.getResolution()

  local newBuffer={
      colorForeground=0xffffff,
      colorBackground=0x000000,
      color=0x00ff,
      width=width,
      height=height,
      parent=parent,
      spans={},
      autoFlushCount=32,
      getResolution=parent.getResolution,
      setResolution=parent.setResolution,
      maxResolution=parent.maxResolution,
      getDepth=parent.getDepth,
      setDepth=parent.setDepth,
      maxDepth=parent.maxDepth,
      getSize=parent.getSize,
    }

  setmetatable(newBuffer,{__index=function(tbl,key) local v=bufferMeta[key] if type(v)=="function" then return function(...) return v(tbl,...) end end return v end})

  return newBuffer
end


return buffer