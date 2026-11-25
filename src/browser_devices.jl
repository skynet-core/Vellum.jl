"""Direct WebGL2 device. Instance attributes contain Vellum trapezoids in Wasm vertex order."""
const _browser_gl_device = @browser canvas -> begin
    @var gl = canvas.getContext("webgl2",d(antialias=true,alpha=true,premultipliedAlpha=true))
    if !gl
        throw(@new Error("WebGL2 is unavailable"))
    end
    @var program = gl.createProgram()
    @var shader = (kind,source) -> begin
        @var handle = gl.createShader(kind)
        gl.shaderSource(handle,source)
        gl.compileShader(handle)
        if !gl.getShaderParameter(handle,gl.COMPILE_STATUS)
            throw(@new Error(gl.getShaderInfoLog(handle)))
        end
        gl.attachShader(program,handle)
        gl.deleteShader(handle)
    end
    shader(gl.VERTEX_SHADER,"""#version 300 es
        layout(location=0) in vec4 edges;
        layout(location=1) in vec2 ys;
        uniform vec4 u[5];
        out vec2 uv;
        void main() {
            int i=gl_VertexID;
            bool right=i==1 || i==4 || i==5, bottom=i==2 || i==3 || i==5;
            vec2 p=vec2(bottom ? (right?edges.w:edges.z) : (right?edges.y:edges.x),bottom?ys.y:ys.x);
            vec2 xy=mat2(u[0].xy,u[0].zw)*p+u[1].xy;
            gl_Position=vec4(xy/u[1].zw*vec2(2.,-2.)+vec2(-1.,1.),0.,1.);
            uv=mat2(u[2].xy,u[2].zw)*p+u[3].xy;
            if (u[3].z>0.5) uv.y=1.-uv.y;
        }""")
    shader(gl.FRAGMENT_SHADER,"""#version 300 es
        precision highp float;
        uniform sampler2D paint;
        uniform vec4 u[5];
        in vec2 uv;
        out vec4 fragment;
        void main() { fragment=texture(paint,uv)*u[4]; }""")
    gl.linkProgram(program)
    if !gl.getProgramParameter(program,gl.LINK_STATUS)
        throw(@new Error(gl.getProgramInfoLog(program)))
    end
    gl.useProgram(program)
    @var uniform = gl.getUniformLocation(program,"u[0]")
    @var meshes = @new WeakMap()
    @var textures = @new WeakMap()
    gl.enable(gl.BLEND)
    gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA)
    @var texture = (w,h,bytes,smooth) -> begin
        @var tex = gl.createTexture()
        gl.bindTexture(gl.TEXTURE_2D,tex)
        gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,w,h,0,gl.RGBA,gl.UNSIGNED_BYTE,bytes)
        @var filter = smooth ? gl.LINEAR : gl.NEAREST
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,filter)
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,filter)
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE)
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE)
        return tex
    end
    @var layer = () -> begin
        @var w = canvas.width
        @var h = canvas.height
        @var tex = texture(w,h,nothing,true)
        @var resolve = gl.createFramebuffer()
        gl.bindFramebuffer(gl.FRAMEBUFFER,resolve)
        gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,tex,0)
        @var samples = Math.min(4,gl.getParameter(gl.MAX_SAMPLES))
        @var ms = gl.createRenderbuffer()
        gl.bindRenderbuffer(gl.RENDERBUFFER,ms)
        gl.renderbufferStorageMultisample(gl.RENDERBUFFER,samples,gl.RGBA8,w,h)
        @var fb = gl.createFramebuffer()
        gl.bindFramebuffer(gl.FRAMEBUFFER,fb)
        gl.framebufferRenderbuffer(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.RENDERBUFFER,ms)
        if gl.checkFramebufferStatus(gl.FRAMEBUFFER)!==gl.FRAMEBUFFER_COMPLETE
            throw(@new Error("WebGL2 could not allocate a compositing layer"))
        end
        return d(tex=tex,fb=fb,resolve=resolve,ms=ms)
    end
    @var beginPass = (target,clear) -> begin
        gl.bindFramebuffer(gl.FRAMEBUFFER,target ? target.fb : nothing)
        gl.viewport(0,0,canvas.width,canvas.height)
        if clear
            gl.clearColor(0,0,0,0)
            gl.clear(gl.COLOR_BUFFER_BIT)
        end
    end
    @var endPass = target -> begin
        if target
            gl.bindFramebuffer(gl.READ_FRAMEBUFFER,target.fb)
            gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER,target.resolve)
            gl.blitFramebuffer(0,0,canvas.width,canvas.height,0,0,canvas.width,canvas.height,gl.COLOR_BUFFER_BIT,gl.NEAREST)
        end
    end
    @var draw = (node,source,params) -> begin
        @var mesh = node.mesh
        @var buffer = meshes.get(mesh)
        if !buffer
            buffer = gl.createBuffer()
            gl.bindBuffer(gl.ARRAY_BUFFER,buffer)
            gl.bufferData(gl.ARRAY_BUFFER,mesh,gl.STATIC_DRAW)
            meshes.set(mesh,buffer)
        else
            gl.bindBuffer(gl.ARRAY_BUFFER,buffer)
        end
        gl.enableVertexAttribArray(0)
        gl.enableVertexAttribArray(1)
        gl.vertexAttribPointer(0,4,gl.FLOAT,false,24,0)
        gl.vertexAttribPointer(1,2,gl.FLOAT,false,24,16)
        gl.vertexAttribDivisor(0,1)
        gl.vertexAttribDivisor(1,1)
        @var tex = source.tex || textures.get(source)
        if !tex
            tex = texture(source.w,source.h,source.pixels,source.smooth)
            textures.set(source,tex)
        end
        params[14] = source.fb ? 1 : 0
        gl.bindTexture(gl.TEXTURE_2D,tex)
        gl.uniform4fv(uniform,params)
        gl.drawArraysInstanced(gl.TRIANGLES,0,6,mesh.length/6)
    end
    @var freeLayer = item -> begin
        gl.deleteTexture(item.tex)
        gl.deleteFramebuffer(item.fb)
        gl.deleteFramebuffer(item.resolve)
        gl.deleteRenderbuffer(item.ms)
    end
    @var drop = src -> begin
        gl.deleteTexture(textures.get(src) || nothing)
        textures.delete(src)
    end
    return d(layer=layer,beginPass=beginPass,endPass=endPass,draw=draw,freeLayer=freeLayer,drop=drop,finish=()->gl.flush())
end

"""Bind Vellum's Wasm meshes directly to WebGPU render passes and a premultiplied texture pipeline."""
const _browser_gpu_device = @browser (canvas,device) -> begin
    @var ctx = canvas.getContext("webgpu")
    @var format = navigator.gpu.getPreferredCanvasFormat()
    ctx.configure(d(device=device,format=format,alphaMode="premultiplied"))
    @var shader = device.createShaderModule(d(code="""
        struct Params { a:vec4f, b:vec4f, c:vec4f, d:vec4f, tint:vec4f }
        @group(0) @binding(0) var<uniform> u:Params;
        @group(0) @binding(1) var tex:texture_2d<f32>;
        @group(0) @binding(2) var smp:sampler;
        struct Vertex { @builtin(position) position:vec4f, @location(0) uv:vec2f }
        @vertex fn vertex(@builtin(vertex_index) i:u32,@location(0) e:vec4f,@location(1) ys:vec2f)->Vertex {
            let right=i==1u || i==4u || i==5u;
            let bottom=i==2u || i==3u || i==5u;
            let p=vec2f(select(select(e.x,e.y,right),select(e.z,e.w,right),bottom),select(ys.x,ys.y,bottom));
            let xy=mat2x2f(u.a.xy,u.a.zw)*p+u.b.xy;
            let uv=mat2x2f(u.c.xy,u.c.zw)*p+u.d.xy;
            return Vertex(vec4f(xy/u.b.zw*vec2f(2,-2)+vec2f(-1,1),0,1),uv);
        }
        @fragment fn fragment(in:Vertex)->@location(0) vec4f {return textureSample(tex,smp,in.uv)*u.tint;}
        """))
    @var blend = d(srcFactor="one",dstFactor="one-minus-src-alpha",operation="add")
    @var pipeline = device.createRenderPipeline(d(layout="auto",
        vertex=d(var"module"=shader,entryPoint="vertex",buffers=[d(arrayStride=24,stepMode="instance",
            attributes=[d(shaderLocation=0,offset=0,format="float32x4"),d(shaderLocation=1,offset=16,format="float32x2")])]),
        fragment=d(var"module"=shader,entryPoint="fragment",targets=[d(format=format,blend=d(color=blend,alpha=blend))]),
        primitive=d(topology="triangle-list"),multisample=d(count=4)))
    @var layout = pipeline.getBindGroupLayout(0)
    @var linear = device.createSampler(d(magFilter="linear",minFilter="linear"))
    @var nearest = device.createSampler(d())
    @var meshes = @new WeakMap()
    @var textures = @new WeakMap()
    @var slots = []
    @var index = 0
    @var encoder = nothing
    @var pass = nothing
    @var main = nothing
    @var makeMS = () -> device.createTexture(d(size=[canvas.width,canvas.height],format=format,sampleCount=4,usage=GPUTextureUsage.RENDER_ATTACHMENT))
    @var layer = () -> begin
        @var tex = device.createTexture(d(size=[canvas.width,canvas.height],format=format,usage=GPUTextureUsage.RENDER_ATTACHMENT+GPUTextureUsage.TEXTURE_BINDING))
        return d(tex=tex,view=tex.createView(),ms=makeMS(),smooth=true)
    end
    @var beginPass = (target,clear) -> begin
        if !encoder
            encoder = device.createCommandEncoder()
            index = 0
            if !main || main.width !== canvas.width || main.height !== canvas.height
                if main
                    main.destroy()
                end
                main = makeMS()
            end
        end
        @var attachment = d(view=(target ? target.ms : main).createView(),resolveTarget=target ? target.view : ctx.getCurrentTexture().createView(),
            loadOp=clear ? "clear" : "load",storeOp="store",clearValue=d(r=0,g=0,b=0,a=0))
        pass = encoder.beginRenderPass(d(colorAttachments=[attachment]))
        pass.setPipeline(pipeline)
    end
    @var draw = (node,source,params) -> begin
        @var mesh = node.mesh
        @var buffer = meshes.get(mesh)
        if !buffer
            buffer = device.createBuffer(d(size=mesh.byteLength,usage=GPUBufferUsage.VERTEX+GPUBufferUsage.COPY_DST))
            device.queue.writeBuffer(buffer,0,mesh)
            meshes.set(mesh,buffer)
        end
        @var tex = source.tex || textures.get(source)
        if !tex
            tex = device.createTexture(d(size=[source.w,source.h],format="rgba8unorm",usage=GPUTextureUsage.TEXTURE_BINDING+GPUTextureUsage.COPY_DST))
            device.queue.writeTexture(d(texture=tex),source.pixels,d(bytesPerRow=4*source.w),[source.w,source.h])
            textures.set(source,tex)
        end
        @var slot = slots[index]
        if !slot
            slot = d(buffer=device.createBuffer(d(size=80,usage=GPUBufferUsage.UNIFORM+GPUBufferUsage.COPY_DST)))
            slots.push(slot)
        end
        index = index+1
        if slot.tex !== tex
            slot.group = device.createBindGroup(d(layout=layout,entries=[d(binding=0,resource=d(buffer=slot.buffer)),
                d(binding=1,resource=tex.createView()),d(binding=2,resource=source.smooth ? linear : nearest)]))
            slot.tex = tex
        end
        device.queue.writeBuffer(slot.buffer,0,params)
        pass.setBindGroup(0,slot.group)
        pass.setVertexBuffer(0,buffer)
        pass.draw(6,mesh.length/6)
    end
    @var finish = () -> begin
        device.queue.submit([encoder.finish()])
        encoder = nothing
    end
    @var drop = src -> begin
        @var tex = textures.get(src)
        if tex
            tex.destroy()
            textures.delete(src)
        end
    end
    return d(layer=layer,beginPass=beginPass,endPass=()->pass.end(),draw=draw,finish=finish,drop=drop,
             freeLayer=t->begin
                 t.tex.destroy()
                 t.ms.destroy()
             end)
end

"""Paint the same Wasm trapezoids through the browser's built-in Canvas 2D context."""
const _browser_canvas_device = @browser canvas -> begin
    @var ctx = nothing
    @var paths = @new WeakMap()
    @var layer = () -> begin
        @var image = document.createElement("canvas")
        image.width = canvas.width
        image.height = canvas.height
        return d(image=image)
    end
    @var beginPass = (target,clear) -> begin
        ctx = (target ? target.image : canvas).getContext("2d")
        if clear
            ctx.resetTransform()
            ctx.clearRect(0,0,canvas.width,canvas.height)
        end
    end
    @var draw = (node,source,u) -> begin
        @var sx = canvas.width/u[6]
        @var sy = canvas.height/u[7]
        ctx.save()
        ctx.setTransform(sx*u[0],sy*u[1],sx*u[2],sy*u[3],sx*u[4],sy*u[5])
        ctx.globalAlpha = u[19]
        @var path = paths.get(node.mesh)
        if !path
            path = @new Path2D()
            @var j = 0
            while j<node.mesh.length
                @var v = node.mesh
                path.moveTo(v[j],v[j+4])
                path.lineTo(v[j+1],v[j+4])
                path.lineTo(v[j+3],v[j+5])
                path.lineTo(v[j+2],v[j+5])
                path.closePath()
                j = j+6
            end
            paths.set(node.mesh,path)
        end
        if node.solid
            ctx.fillStyle = node.solid
            ctx.fill(path)
        elseif node.gradient
            @var g = node.gradient
            @var paint = ctx.createLinearGradient(g.start.x,g.start.y,g.end.x,g.end.y)
            g.colorStops.forEach(s->paint.addColorStop(s.offset,s.color))
            ctx.fillStyle = paint
            ctx.fill(path)
        else
            if !source.image
                source.image = document.createElement("canvas")
                source.image.width = source.w
                source.image.height = source.h
                source.image.getContext("2d").putImageData(@new(ImageData(@new(Uint8ClampedArray(source.straight)),source.w,source.h)),0,0)
            end
            ctx.clip(path)
            ctx.imageSmoothingEnabled = source.smooth !== false
            ctx.drawImage(source.image,0,0,1/u[8],1/u[11])
        end
        ctx.restore()
    end
    return d(layer=layer,beginPass=beginPass,endPass=()->nothing,draw=draw,finish=()->nothing,drop=()->nothing,freeLayer=()->nothing)
end

"""Prepare retained geometry and textures, isolate nested groups, and submit draws to the selected device."""
const _browser_surface = @browser (target,canvas,device) -> begin
    @var unit = @new Float32Array([0,1,0,1,0,1])
    @var ident = [1,0,0,1,0,0]
    @var white = d(w=1,h=1,pixels=@new(Uint8Array([255,255,255,255])),smooth=false)
    @var cached = @new WeakMap()
    @var ramps = @new Map()
    @var layers = []
    @var width = 0
    @var height = 0
    @var rgba = css -> begin
        @var color = css.slice(1)
        return [parseInt(color.slice(0,2),16),parseInt(color.slice(2,4),16),parseInt(color.slice(4,6),16),color.length===8 ? parseInt(color.slice(6),16) : 255]
    end
    @var image = (w,h,bytes,smooth) -> begin
        @var pixels = @new Uint8Array(bytes.length)
        @var i = 0
        while i<bytes.length
            @var a = bytes[i+3]/255
            pixels[i] = Math.round(bytes[i]*a)
            pixels[i+1] = Math.round(bytes[i+1]*a)
            pixels[i+2] = Math.round(bytes[i+2]*a)
            pixels[i+3] = bytes[i+3]
            i = i+4
        end
        return d(w=w,h=h,pixels=pixels,straight=bytes,smooth=smooth)
    end
    @var ramp = stops -> begin
        @var key = JSON.stringify(stops)
        if !ramps.has(key)
            @var bytes = @new Uint8Array(4096)
            @var colors = stops.map(s->rgba(s.color))
            @var j = 0
            @var i = 0
            while i<1024
                @var t = i/1023
                while j+1<stops.length && t>=stops[j+1].offset
                    j = j+1
                end
                @var k = Math.min(j+1,stops.length-1)
                @var mix = k===j ? 0 : Math.max(0,(t-stops[j].offset)/(stops[k].offset-stops[j].offset))
                colors[j].forEach((c,n)->begin
                    bytes[4*i+n] = Math.round(c+(colors[k][n]-c)*mix)
                end)
                i = i+1
            end
            ramps.set(key,image(1024,1,bytes,true))
        end
        return ramps.get(key)
    end
    @var prepare = op -> begin
        if cached.has(op)
            return cached.get(op)
        end
        @var n = d(kind=op.kind,mesh=op.mesh || unit,m=op.matrix || ident,uv=ident,source=white,tint=[1,1,1,1])
        if op.kind==="image"
            n.source = image(op.width,op.height,op.data,op.sampling!=="nearest")
            @var m = op.matrix
            n.m = [m[0]*op.width,m[1]*op.width,m[2]*op.height,m[3]*op.height,m[4],m[5]]
        elseif op.kind==="fill" || op.kind==="stroke"
            n.solid = op.style.color
            @var c = rgba(n.solid)
            @var a = op.style.alpha
            n.tint = [c[0]/255*a,c[1]/255*a,c[2]/255*a,a]
        elseif op.kind==="gradient"
            n.gradient = op.options
            @var a = op.options.start
            @var b = op.options.end
            @var dx = b.x-a.x
            @var dy = b.y-a.y
            @var t = dx*dx+dy*dy
            n.uv = [dx/t,0,dy/t,0,(0-a.x*dx-a.y*dy)/t,0.5]
            n.tint = [op.alpha,op.alpha,op.alpha,op.alpha]
            n.source = ramp(op.options.colorStops)
        elseif op.kind==="push"
            n.alpha = op.alpha
        elseif op.kind==="pop"
            n.clipped = Boolean(op.mesh)
        end
        cached.set(op,n)
        return n
    end
    @var resize = (w,h,density) -> begin
        @var pw = Math.max(1,Math.round(w*density))
        @var ph = Math.max(1,Math.round(h*density))
        if canvas.width!==pw || canvas.height!==ph
            layers.forEach(device.freeLayer)
            layers = []
            canvas.width = pw
            canvas.height = ph
        end
        canvas.style.width = String(w)+"px"
        canvas.style.height = String(h)+"px"
        width = w
        height = h
    end
    @var params = @new Float32Array(20)
    @var issue = (node,source,m,uv,tint) -> begin
        if node.mesh.length>0
            params.set(m,0)
            params[6] = width
            params[7] = height
            params.set(uv,8)
            params[14] = 0
            params.set(tint,16)
            device.draw(node,source,params)
        end
    end
    @var render = replay -> begin
        @var depth = 0
        @var alpha = []
        @var dest = nothing
        device.beginPass(dest,true)
        replay(n->begin
            if n.kind==="push"
                device.endPass(dest)
                if !layers[depth]
                    layers[depth] = device.layer()
                end
                dest = layers[depth]
                alpha.push(n.alpha)
                depth = depth+1
                device.beginPass(dest,true)
            elseif n.kind==="pop"
                device.endPass(dest)
                @var child = dest
                depth = depth-1
                dest = depth>0 ? layers[depth-1] : nothing
                device.beginPass(dest,false)
                @var a = alpha.pop()
                @var m = n.clipped ? ident : [width,0,0,height,0,0]
                @var uv = n.clipped ? [1/width,0,0,1/height,0,0] : ident
                issue(n,child,m,uv,[a,a,a,a])
            else
                issue(n,n.source,n.m,n.uv,n.tint)
            end
        end)
        device.endPass(dest)
        device.finish()
    end
    # Browser shaping rasterizes live strings into small glyph-run textures only.
    # Captured Vellum text is already vector geometry in the Wasm stream.
    @var label = (text,size,color,density) -> begin
        @var glyphs = document.createElement("canvas")
        @var ctx = glyphs.getContext("2d")
        @var font = String(size*density)+"px VellumView"
        ctx.font = font
        @var metrics = ctx.measureText(text)
        @var left = Math.ceil(metrics.actualBoundingBoxLeft)+1
        @var top = Math.ceil(metrics.actualBoundingBoxAscent)+1
        glyphs.width = Math.max(1,left+Math.ceil(metrics.actualBoundingBoxRight)+1)
        glyphs.height = Math.max(1,top+Math.ceil(metrics.actualBoundingBoxDescent)+1)
        ctx.font = font
        ctx.fillStyle = color
        ctx.fillText(text,left,top)
        @var src = image(glyphs.width,glyphs.height,ctx.getImageData(0,0,glyphs.width,glyphs.height).data,true)
        src.image = glyphs
        return d(source=src,left=left/density,top=top/density)
    end
    return d(canvas=canvas,prepare=prepare,render=render,resize=resize,unit=unit,white=white,identity=ident,label=label,drop=device.drop)
end

"""Request exactly the chosen browser API and propagate context creation failures to the viewer."""
const _browser_open_device = @browser target -> begin
    @var canvas = document.createElement("canvas")
    if target==="webgpu"
        if !navigator.gpu
            return Promise.reject("WebGPU is unavailable")
        end
        return navigator.gpu.requestAdapter().then(adapter->begin
            if !adapter
                throw(@new Error("WebGPU adapter unavailable"))
            end
            return adapter.requestDevice()
        end).then(device->surface(target,canvas,gpuDevice(canvas,device)))
    end
    return Promise.resolve().then(()->surface(target,canvas,target==="webgl2" ? glDevice(canvas) : canvasDevice(canvas)))
end
