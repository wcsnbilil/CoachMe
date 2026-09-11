from pathlib import Path
import argparse,torch,numpy as np,coremltools as ct
from model import EventDetector
p=argparse.ArgumentParser();p.add_argument('--weights',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(4)
m=EventDetector(False,1.,1,256,True,False).eval();m.load_state_dict(torch.load(a.weights,map_location='cpu',weights_only=True)['model_state_dict'],strict=True)
class Encoder(torch.nn.Module):
 def __init__(self,m):super().__init__();self.cnn=m.cnn
 def forward(self,x):return self.cnn(x).mean(3).mean(2)
class Sequence(torch.nn.Module):
 def __init__(self,m):super().__init__();self.rnn=m.rnn;self.lin=m.lin
 def forward(self,x):return self.lin(self.rnn(x)[0])
for name,model,example,shape,inp,out in [('SwingNetEncoder',Encoder(m).eval(),torch.zeros(1,3,160,160),(1,3,160,160),'image','features'),('SwingNetSequence',Sequence(m).eval(),torch.zeros(1,64,1280),(1,ct.RangeDim(lower_bound=1,upper_bound=64,default=64),1280),'features','logits')]:
 traced=torch.jit.trace(model,example)
 converted=ct.convert(traced,inputs=[ct.TensorType(name=inp,shape=shape,dtype=np.float32)],outputs=[ct.TensorType(name=out,dtype=np.float32)],minimum_deployment_target=ct.target.iOS17,convert_to='mlprogram',compute_precision=ct.precision.FLOAT32)
 converted.author='GolfDB / William McNally et al.';converted.short_description='SwingNet pretrained 1800, split for on-device swing event detection.';converted.user_defined_metadata['source']='https://github.com/wmcnally/golfdb';converted.user_defined_metadata['checkpoint']='swingnet_1800.pth.tar';converted.save(str(a.output/(name+'.mlpackage')))
 print('Saved',name,flush=True)
